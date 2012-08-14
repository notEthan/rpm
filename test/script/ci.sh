#!/bin/bash

# Script to run test suites in CI or in development mode.  This script handles
# checking out test dependencies (currently rpm_test_app and it's dependencies)
# and executing them.
#
# It relies on 2 environment variables:
#
# RUBY - The rvm ruby you want to use (e.g. 1.8.7, ree, jruby)
#
# BRANCH - The rpm_test_app branch you want to use (e.g. rails20, rails31)
#
# Example usage:
# RUBY=ree BRANCH=rails20 test/script/ci.sh
#
# RUBY=ree BRANCH=rails20 test/script/ci.sh
#
# RUBY=jruby BRANCH=rails22 test/script/ci.sh

echo "Executing $0"
echo "Running in $(pwd)"

# print commands in this script as they're invoked
#set -x
# fail if any command fails
set -e

# check for require environment variables
if [ "x$RUBY" == "x" ]; then
  echo '$RUBY is undefined'
  echo 'defaulting to 1.9.3'
  export RUBY=1.9.3
fi
if [ "x$BRANCH" == "x" ]; then
  echo '$BRANCH is undefined'
  echo 'defaulting to rails31'
  export BRANCH=rails31
fi

if [ "x$JOB_NAME" == "x" ]; then
  echo '$JOB_NAME is undefined'
  echo 'defaulting to clrun'
  export PROJECT_NAME=clrun
else
  echo "setting PROJECT_NAME to $JOB_NAME"
  export PROJECT_NAME="$JOB_NAME"
fi

. "$HOME/.rvm/scripts/rvm"
rvm use $RUBY || rvm install $RUBY
echo `which ruby`

# make sure that we're in the project root
script_dirname=`dirname $0`
cd "$script_dirname/../../"
pwd

rm -rf tmp
mkdir -p tmp
cd tmp


#rpm_test_app_cache=~/.rpm_test_app_cache
rpm_test_app_cache=~/workspace/.rpm_test_app_cache
(
  echo "updating local cache of rpm_test_app in $rpm_test_app_cache"
  git clone --mirror git://github.com/newrelic/rpm_test_app.git $rpm_test_app_cache || true
  cd $rpm_test_app_cache
)

git clone $rpm_test_app_cache rpm_test_app
cd rpm_test_app || true # rvm overrides cd and it's f-ing up the build by exiting 2

git checkout -t origin/$BRANCH || git checkout $BRANCH


# Re-write database.yml to this here doc
( cat << "YAML" ) > config/database.yml
# Shared properties for mysql db
mysql: &mysql
  adapter: mysql
  socket: <%= (`uname -s` =~ /Linux/ ) ? "" :"/tmp/mysql.sock" %>
  username: root
  host: localhost
  database: <%= [ 'rails_blog', ENV['BRANCH'], ENV['RUBY'], ENV['PROJECT_NAME'] ].compact.join('_') %>

# Shared properties for postgres.  This won't work with our schema but
# Does work with agent tests
sqlite3: &sqlite3
<% if defined?(JRuby) %>
  adapter: jdbcsqlite3
<% else %>
  adapter: sqlite3
<% end %>
  database: db/all.sqlite3
  pool: 5
  timeout: 5000
  host: localhost
  
# SQLite version 3.x
#   gem install sqlite3-ruby (not necessary on OS X Leopard)
development:
  <<: *sqlite3

test:
  <<: *mysql

production:
  <<: *mysql
YAML


mkdir -p log
mkdir -p tmp
if [ "x$BRANCH" == "xrails20" ]; then
  printf "\e[0;31;49mWarning:\e[0m "
  echo "Testing against the rails20 branch requires your changes to be committed. Uncommitted changes will not be used."
  mkdir -p vendor/plugins
  git clone ../.. vendor/plugins/newrelic_rpm
else
  perl -p -i'.bak' -e 's#gem .newrelic_rpm.*$#gem "newrelic_rpm", :path => "\.\.\/\.\.\/"#' Gemfile
fi

# save time by reusing the gemset if it exists

gemset=ruby_agent_tests_$BRANCH
rvm gemset use $gemset || ( rvm gemset create $gemset && rvm gemset use $gemset )

if [ "x$RUBY" == "x1.8.6" ]; then
  # Bundler 0.1 dropped support for ruby 1.8.6
  gem install bundler -v'~>1.0.0' --no-rdoc --no-ri
else
  gem install bundler --no-rdoc --no-ri
fi


export RAILS_ENV=test
bundle

# FIXME:  Here we actually trigger the tests. Since the agent deals so heavily
# in units of time we have many tests that assert that durations are measured
# correctly.  These almost always pass, but as the CI machine has come under
# heavier load there tend to be discrepencies between the duration measured in
# the test and the duration the agent measures.  This is due to lags in CPU
# scheduling since many processes are running on the box simultaneously.
# To reduce the noise from these sporardic failures we rerun the test suite if
# there are failures to see if they are transient (instead of re-running it by
# hand).  Ultimately we'll move towards a more elegant solution.
bundle exec rake --trace db:create:all test:newrelic || bundle exec rake --trace test:newrelic || bundle exec rake --trace test:newrelic
