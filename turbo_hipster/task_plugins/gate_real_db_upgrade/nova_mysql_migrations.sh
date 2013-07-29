#!/bin/bash

# $1 is the unique id
# $2 is the working dir path
# $3 is the path to the git repo path
# $4 is the nova db user
# $5 is the nova db password
# $6 is the nova db name
# $7 is the path to the dataset to test against
# $8 is the pip cache dir

pip_requires() {
  requires="tools/pip-requires"
  if [ ! -e $requires ]
  then
    requires="requirements.txt"
  fi
  echo "Install pip requirements from $requires"
  pip install -q -r $requires
  echo "Requirements installed"
}

db_sync() {
# $1 is the test target
# $2 is the working dir path
# $3 is the path to the git repo path
# $4 is the nova db user
# $5 is the nova db password
# $6 is the nova db name
# $7 is the logging.conf for openstack

  # Create a nova.conf file
  cat - > $3/nova-$1.conf <<EOF
[DEFAULT]
sql_connection = mysql://$4:$5@localhost/$6?charset=utf8
log_config = $7
EOF

  find $3 -type f -name "*.pyc" -exec rm -f {} \;

  nova_manage="$3/bin/nova-manage"
  if [ -e $nova_manage ]
  then
    echo "***** DB upgrade to state of $1 starts *****"
    python $nova_manage --config-file $3/nova-$1.conf db sync
  else
    python setup.py clean
    python setup.py develop
    echo "***** DB upgrade to state of $1 starts *****"
    nova-manage --config-file $3/nova-$1.conf db sync
  fi
  echo "***** DB upgrade to state of $1 finished *****"
}

echo "To execute this script manually, run this:"
echo "$0 $1 $2 $3 $4 $5 $6 $7 $8"

set -x

# Setup the environment
export PATH=/usr/lib/ccache:$PATH
export PIP_DOWNLOAD_CACHE=$8

# Restore database to known good state
echo "Restoring test database $6"
mysql -u root -e "drop database $6"
mysql -u root -e "create database $7"
mysql -u root -e "create user '$4'@'localhost' identified by '$5';"
mysql -u root -e "grant all privileges on $6.* TO '$4'@'localhost';"
mysql -u $4 --password=$5 $6 < /$7/$6.sql

echo "Build test environment"
cd $3

set +x
echo "Setting up virtual env"
source ~/.bashrc
source /etc/bash_completion.d/virtualenvwrapper
rm -rf ~/.virtualenvs/$1
mkvirtualenv $1
toggleglobalsitepackages
set -x
export PYTHONPATH=$PYTHONPATH:$3

# Some databases are from Folsom
version=`mysql -u $5 --password=$6 $7 -e "select * from migrate_version \G" | grep version | sed 's/.*: //'`
echo "Schema version is $version"

# zuul puts us in a headless mode, lets check it out into a working branch
git checkout -b working

# Make sure the test DB is up to date with trunk
if [ `git show | grep "^\-\-\-" | grep "migrate_repo/versions" | wc -l` -gt 0 ]
then
  echo "This change alters an existing migration, skipping trunk updates."
else
  echo "Update database to current state of trunk"
  git checkout master
  pip_requires
  db_sync "trunk" $2 $3 $4 $5 $6 $7/logging.conf
  git checkout working
fi

# Now run the patchset
echo "Now test the patchset"
pip_requires
db_sync "patchset" $2 $3 $4 $5 $6 $7/logging.conf

# Determine the final schema version
version=`mysql -u $4 --password=$5 $6 -e "select * from migrate_version \G" | grep version | sed 's/.*: //'`
echo "Final schema version is $version"

# cleanup branches
git checkout master
git branch -D working

# Cleanup virtual env
set +x
echo "Cleaning up virtual env"
deactivate
rmvirtualenv $1
set -x

echo "done" 
