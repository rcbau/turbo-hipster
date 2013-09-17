#!/bin/bash
#
# Copyright 2013 Rackspace Australia
#
# Licensed under the Apache License, Version 2.0 (the "License"); you may
# not use this file except in compliance with the License. You may obtain
# a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
# WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
# License for the specific language governing permissions and limitations
# under the License.


# $1 is the unique id
# $2 is the working dir path
# $3 is the path to the git repo path
# $4 is the nova db user
# $5 is the nova db password
# $6 is the nova db name
# $7 is the path to the dataset to test against
# $8 is the logging.conf for openstack
# $9 is the pip cache dir

pip_requires() {
  pip install -q mysql-python
  pip install -q eventlet
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
# $8 is any sync options

  # Create a nova.conf file
  cat - > $2/nova-$1.conf <<EOF
[DEFAULT]
sql_connection = mysql://$4:$5@localhost/$6?charset=utf8
log_config = $7
EOF

  find $3 -type f -name "*.pyc" -exec rm -f {} \;
  echo "***** Start DB upgrade to state of $1 *****"
  nova_manage="$3/bin/nova-manage"
  if [ -e $nova_manage ]
  then
    set -x
    python $nova_manage --config-file $2/nova-$1.conf db sync $8
  else
    python setup.py -q clean
    python setup.py -q develop
    python setup.py -q install
    set -x
    nova-manage --config-file $2/nova-$1.conf db sync $8
  fi
  set +x
  echo "***** Finished DB upgrade to state of $1 *****"
}

echo "To execute this script manually, run this:"
echo "$0 $1 $2 $3 $4 $5 $6 $7 $8 $9"


# Setup the environment
export PATH=/usr/lib/ccache:$PATH
export PIP_DOWNLOAD_CACHE=$9

# Restore database to known good state
echo "Restoring test database $6"
set -x
mysql -u $4 --password=$5 -e "drop database $6"
mysql -u $4 --password=$5 -e "create database $6"
mysql -u $4 --password=$5 $6 < /$7
set +x

echo "Build test environment"
cd $3

echo "Setting up virtual env"
source ~/.bashrc
source /etc/bash_completion.d/virtualenvwrapper
rm -rf ~/.virtualenvs/$1
mkvirtualenv $1
toggleglobalsitepackages
export PYTHONPATH=$PYTHONPATH:$3

# Some databases are from Folsom
version=`mysql -u $4 --password=$5 $6 -e "select * from migrate_version \G" | grep version | sed 's/.*: //'`
echo "Schema version is $version"

git branch -D working
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
  db_sync "trunk" $2 $3 $4 $5 $6 $8
  git checkout working
fi

# Now run the patchset
echo "Now test the patchset"
pip_requires
db_sync "patchset" $2 $3 $4 $5 $6 $8

# Determine the schema version
version=`mysql -u $4 --password=$5 $6 -e "select * from migrate_version \G" | grep version | sed 's/.*: //'`
echo "Schema version is $version"

#echo "Now downgrade all the way back to Folsom"
#db_sync "patchset" $2 $3 $4 $5 $6 $8 "--version 133"

# Determine the schema version
#version=`mysql -u $4 --password=$5 $6 -e "select * from migrate_version \G" | grep version | sed 's/.*: //'`
#echo "Schema version is $version"

#echo "And now back up to head from Folsom"
#db_sync "patchset" $2 $3 $4 $5 $6 $8

# Determine the final schema version
version=`mysql -u $4 --password=$5 $6 -e "select * from migrate_version \G" | grep version | sed 's/.*: //'`
echo "Final schema version is $version"

# cleanup branches
git checkout master
git branch -D working

# Cleanup virtual env

echo "Cleaning up virtual env"
deactivate
rmvirtualenv $1
