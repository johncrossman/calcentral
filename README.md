# ETS Junction

Looking for the CalCentral web application? That code is maintained by Student Information Systems at https://github.com/sis-berkeley-edu/calcentral.

* Master Build: [![Build Status](https://api.travis-ci.org/ets-berkeley-edu/calcentral.svg?branch=master)](https://travis-ci.org/ets-berkeley-edu/calcentral)

![Cartoon image of a maze of railroad tracks](src/assets/images/conjunction-junction.jpg)

## Dependencies

* Administrator privileges
* [Bundler](http://gembundler.com/rails3.html)
* [Git](https://help.github.com/articles/set-up-git)
* [JDBC Oracle driver](http://www.oracle.com/technetwork/database/enterprise-edition/jdbc-112010-090769.html)
* [Java 8 SDK](http://www.oracle.com/technetwork/java/javase/downloads/index.html)
* [JRuby](http://jruby.org/) (version per [.ruby-version](.ruby-version))
* [Node.js](http://nodejs.org/) (version per [.nvmrc](.nvmrc))
* [PostgreSQL](http://www.postgresql.org/)
* [Rubygems 2.7.10](https://rubygems.org/pages/download)
* [RVM](https://rvm.io/rvm/install/) - Ruby version managers
* [xvfb](http://xquartz.macosforge.org/landing/) - xvfb headless browser, included for Macs with XQuartz

## Developer Setup

1. Install Java 8 JDK ([8u172](http://www.oracle.com/technetwork/java/javase/downloads/index.html)):
http://www.oracle.com/technetwork/java/javase/downloads/index.html

1. Install Postgres:

    **Note**: To install Postgres, you must first install [Homebrew](http://brew.sh/).

    Install Homebrew with the following command:
    ```bash
    ruby -e "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/master/install)"
    ```
    Run the following command in Terminal after installation:
    ```bash
    brew --version
    ```

    Then run the following:
    ```bash
    brew update
    brew install postgresql
    ```

    1. __For Mountain Lion & Mavericks users ONLY:__  [Fix Postgres paths](http://nextmarvel.net/blog/2011/09/brew-install-postgresql-on-os-x-lion/).

    1. __For Mountain Lion & Mavericks users ONLY:__ If you can connect to Postgres via psql, but not via JDBC (you see "Connection refused" errors in the CalCentral app log), then edit `/usr/local/var/postgres/pg_hba.conf` and make sure you have these lines:

        ```
        host    all             all             127.0.0.1/32            md5
        host    all             all             samehost                md5
        ```

    1. __For Mountain Lion & Mavericks users ONLY:__ [Install XQuartz](http://xquartz.macosforge.org/landing/) and make sure that /opt/X11/bin is on your `PATH`.

1. Start Postgres, add users and create the necessary databases. (If your PostgreSQL server is managed externally, you'll probably need to create a schema that matches the database username. See [CLC-893](https://jira.media.berkeley.edu/jira/browse/CLC-893) for details.):

    ```bash
    pg_ctl -D /usr/local/var/postgres -l /usr/local/var/postgres/server.log start
    psql postgres
    create database calcentral_development;
    create user calcentral_development with password 'secret' createdb;
    grant all privileges on database calcentral_development to calcentral_development;
    alter database calcentral_development owner to calcentral_development;
    create database calcentral;
    create user calcentral with password 'secret' createdb;
    grant all privileges on database calcentral to calcentral;
    alter database calcentral owner to calcentral;
    create database calcentral_test;
    create user calcentral_test with password 'secret' createdb;
    grant all privileges on database calcentral_test to calcentral_test;
    alter database calcentral_test owner to calcentral_test;
    create database edodb_test;
    grant all privileges on database edodb_test to calcentral_test;
    alter database edodb_test owner to calcentral_test;
    \q
    ```

    **Note**: At this point, exit out of Postgres. To do this, type "\q" and then press ENTER.

1. [Fork this repository](https://github.com/ets-berkeley-edu/calcentral/wiki/Workflow), then:

    with ssh ([note](https://help.github.com/articles/connecting-to-github-with-ssh/))

    ```bash
    git clone git@github.com:[your GitHub Account]/junction.git
    # e.g. git clone git@github.com:christianv/junction.git
    ```

    or via https - ([note](https://help.github.com/articles/caching-your-github-password-in-git/))
    ```bash
    git clone https://github.com/[your Github Account]/junction.git
    # e.g. git clone https://github.com/christianv/junction.git

    ```

1. Go inside the `junction` repository:

    ```bash
    cd junction
    # Answer "yes" if it asks you to trust a new .rvmrc file.
    ```

1. Install JRuby (see [.ruby-version](.ruby-version) for required version):

     **Note**: To install JRuby, you must first install [rvm](https://rvm.io/rvm/install/).

    ```bash
    rvm get head
    rvm install jruby-[put-version-here]
    cd ..
    cd junction
    # Answer "yes" again if it asks you to trust a new .rvmrc file.
    rvm list
    # Make sure that everything looks fine
    # If it mentions "broken", you'll need to reinstall
    ```

1. Make JRuby faster for local development by running this or put in your .bashrc:

    ``` bash
    export JRUBY_OPTS="--dev"
    ```
1. Configure Default JRuby and Gemset

    ```bash
    cd ~
    rvm use --default # This may output 'Unknown ruby string...', which can be ignored.
    rvm gemset use global
    ```

1. Download and install xvfb. On a Mac, you get xvfb by [installing XQuartz](http://xquartz.macosforge.org/landing/).

1. Download the appropriate gems with [Bundler](http://gembundler.com/rails3.html):

    **Important**: Make sure you have the JRuby-upgraded codebase in your junction directory before running `bundle install`.

    ```bash
    rvm rubygems 2.7.10 --force
    gem --version
    # Should output '2.7.10'

    gem uninstall bundler --force -x
    gem install bundler --version="1.17.3"
    bundle install
    ```

1. Set up a local settings directory:

    ```bash
    mkdir ~/.calcentral_config
    ```

    Default settings are loaded from your source code in `config/settings.yml` and `config/settings/ENVIRONMENT_NAME.yml`.
    For example, the configuration used when running tests with `RAILS_ENV=test` is determined by the combination of
    `config/settings/test.yml` and `config/settings.yml`. Because we don't store passwords and other sensitive data in source code,
    any RAILS_ENV other than `test` requires overriding some default settings. Do this by creating `ENVIRONMENT.local.yml` files
    in your `~/.calcentral_config` directory.

    *development.local configs*

    Your `~/.calcentral_config/development.local.yml` file may include access tokens and URLs for a locally running
    Canvas server. You can also create Ruby configuration files like "settings.local.rb" and "development.local.rb" to
    amend the standard `config/environments/*.rb` files.

    Your `development.local` config must have:
    ```yaml
    vue:
      localhost_base_url: 'http://localhost:8080'
    ```

1. Install JDBC driver (for Oracle connection)
    * Download [ojdbc8.jar](https://www.oracle.com/database/technologies/jdbc-ucp-122-downloads.html)
    * Note: You do not have to open the file.
    * Copy `ojdbc8.jar` to `~/.rvm/rubies/jruby-9.2.13.0/lib/`

1. Initialize PostgreSQL database tables:

    ```bash
    bundle exec rake environment db:schema:load db:seed
    ```

1. Make yourself powerful:

    ```bash
    bundle exec rake superuser:create UID=[your numeric CalNet UID]
    # e.g. rake superuser:create UID=61889
    ```

1. Install the front-end tools:

    ```bash
    brew install node
    npm install
    nvm use
    ```

1. Start the front-end development server

    ```bash
    # starts development server
    npm run serve-vue
    ```

    Your browser will automatically load the Junction front-end on **_localhost:8080_**.

1. Start the server:

    ```bash
    rails s
    ```

    Access Rails server at **_localhost:3000_**.

## Back-end Testing

Back-end (rspec) tests live in `spec/*`.

To run the tests from the command line:

```bash
rspec
```

## Front-end Linting

Front-end linting can be done by running the following commands:

```bash
npm run lint-vue
```

This will check for any potential JavaScript issues and whether you formatted the code correctly.

## Debugging

### Emulating production mode locally

1. Make sure you have a separate production database:

    ```bash
    psql postgres
    create database calcentral_production;
    grant all privileges on database calcentral_production to calcentral_development;
    ```

1. In calcentral_config/production.local.yml, you'll need the following entries:

    ```yaml
    secret_token: 'Some random 30-char string'
    postgres: '...'
    application:
      serve_static_assets: true
    ```

1. Populate the production db by invoking your production settings:

    ```bash
    RAILS_ENV="production" rake db:schema:load db:seed
    ```

1. Precompile the front-end assets

    ```bash
    npm run build-vue
    ```

1. Start the server in production mode:

    ```bash
    rails s -e production
    ```

1. If you're not able to connect to Google or Canvas, export the data in the oauth2 from your development db and import them into the same table in your production db.

### Test connection

Make sure you are on the Berkeley network or connected through [preconfigured VPN](https://kb.berkeley.edu/page.php?id=23065) for the Oracle connection.
If you use a VPN, use group `1-Campus_VPN`.

### Enable basic authentication

Basic authentication will enable you to log in without using CAS.
This is necessary when your application can't be CAS authenticated or when you're testing mobile browsers.
**Note**: only enable this in fake mode or in development.

1. Add the following setting to your `environment.yml` file (e.g. `development.yml`):

    ```bash
    developer_auth:
      enabled: true
      password: topsecret!
    ```

1. (Re)start the server for the changes to take effect.

1. Click on the footer (Berkeley logo) when you load the page.

1. You should be seeing the [Basic Auth screen](http://cl.ly/SA6C). As the login you should use a UID (e.g. `61889` for oski) and then the password from the settings file.

### "Act As" another user

To help another user debug an issue, you can "become" him or her. To assume the identity of another user, you must:

- Currently be logged in as a designated superuser
- Be accessing a machine/server which the other user has previously logged into (e.g. from localhost, you can't act as a random student, since that student has probably never logged in at your terminal)

Access the URL:

```
https://[hostname]/act_as?uid=123456
```

where 123456 is the UID of the user to emulate.

**Note**: The Act As feature will only reveal data from data sources we control, e.g. Canvas. Google data will be completely suppressed, __EXCEPT__ for test users. The following user uids have been configured as test users.
* 11002820 - "Tammi Chang"
* 61889 - "Oski Bear"
* All IDs listed on the [Universal Calnet Test IDs](https://wikihub.berkeley.edu/display/calnet/Universal+Test+IDs) page

To become yourself again, access:

```
https://[hostname]/stop_act_as
```

### Logging

Logging behavior and destination can be controlled from the command line or shell scripts via env variables:

* `LOGGER_STDOUT=false` - Only log to the default files
* `LOGGER_STDOUT=true` - Log to standard output as well as the default files
* `LOGGER_STDOUT=only` - Only log to standard output
* `LOGGER_LEVEL=DEBUG` - Set logging level; acceptable values are 'FATAL', 'ERROR', 'WARN', 'INFO', and 'DEBUG'

### Tips

1. On Mac OS X, to get RubyMine to pick up the necessary environment variables, open a new shell, set the environment variables, and:

    ```bash
    /Applications/RubyMine.app/Contents/MacOS/rubymine &
    ```

1. If you want to explore the Oracle database on Mac OS X, use [SQL Developer](http://www.oracle.com/technetwork/developer-tools/sql-developer/overview/index.html).

## Creating timeshifted fake data feeds

Proxies running in fake mode use WebMock to substitute fixture data for connections to external services (Canvas, Google, etc). This fake data lives in `fixtures/json` and `fixtures/xml`.

Fixture files can represent time information by tokens that are substituted with appropriately shifted values when fixture data is loaded. See `config/initializers/timeshift.rb` for the dictionary of substitutions.

## Rake tasks:

To view other rake tasks for the project: `rake -T`

## Installing Memcached:

Dev, QA, and Production CalCentral environments use memcached as a cache store in place of the default ActiveSupport cache store.

To set this up locally, perform the following steps:

1. Install and run [memcached](http://memcached.org/).

1. Add the following lines to development.local.yml:

```yaml
cache:
  store: "memcached"
```

## Memcached tasks:

A few rake tasks to help monitor statistics and more:

* `rake memcached:clear` - Invalidate all memcached keys and reset memcached stats from all cluster nodes.
* `rake memcached:get_stats` - Fetch memcached stats from all cluster nodes. Per-slab stats may point out specific types of data which are being overcached or undercached, or indicate a need to reconfigure memcached.
* `rake memcached:dump_slab slab=NUMBER` - Shows which cached items are currently stored in the "slab" with the given ID. The list won't include the keys of expired or evicted items.

* __WARNING:__ do not run `rake memcached:clear` on the production cluster unless you know what you're doing!
* All `memcached` tasks take the optional param of `hosts`. So, if say you weren't running these tasks on the cluster layers themselves, or only wanted to tinker with a certain subset of clusters: `rake memcached:get_stats hosts="localhost:11212,localhost:11213,localhost:11214"`

## Using the feature toggle:

To selectively enable/disable a feature, add a property to the `features` section of settings.yml, e.g.:

```yaml
features:
  wizbang: false
  neato: true
```

## Keeping developer seed data updated

`seeds.rb` is intended for use only on developer machines, so they have a semi-realistic copy of production lists of
superusers, links, etc. `./db/developer-seed-data.sql` has the data used by `rake db:seed`. Occasionally we'll want to
update it from production. To do that, log into a prod node and do:

```bash
pg_dump calcentral -O -x --inserts --clean -f developer-seed-data.sql -t oec_course_codes \
-h postgres-hostname -p postgres-port-number -U calcentral
```

Copy the file into your source tree and get it merged into master.
