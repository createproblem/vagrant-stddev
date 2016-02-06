#!/bin/bash
#
# provision.sh
#
# This file is specified in Vagrantfile and is loaded by Vagrant as the primary
# provisioning script whenever the commands `vagrant up`, `vagrant provision`,
# or `vagrant reload` are used. It provides all of the default packages and
# configurations included with Varying Vagrant Vagrants.

# By storing the date now, we can calculate the duration of provisioning at the
# end of this script.
start_seconds="$(date +%s)"

# PACKAGE INSTALLATION
#
# Build a bash array to pass all of the packages we want to install to a single
# apt-get command. This avoids doing all the leg work each time a package is
# set to install. It also allows us to easily comment out or add single
# packages. We set the array as empty to begin with so that we can append
# individual packages to it as required.
apt_package_install_list=()

# Start with a bash array containing all packages we want to install in the
# virtual machine. We'll then loop through each of these and check individual
# status before adding them to the apt_package_install_list array.
apt_package_check_list=(
    # PHP5
    #
    # Our base packages for php5. As long as php5-fpm and php5-cli are
    # installed, there is no need to install the general php5 package, which
    # can sometimes install apache as a requirement.
    php5-fpm
    php5-cli

    # Common and dev packages for php
    php5-common
    php5-dev

    # Extra PHP modules that we find useful
    php5-mcrypt
    php5-curl
    php-pear
    php5-gd
    php5-mysql

    # nginx is installed as the default web server
    nginx

    # mysql is the default database
    mysql-server

    # other packages that come in handy
    imagemagick
    git-core
    zip
    unzip
    ngrep
    curl
    make

    # ntp service to keep clock current
    ntp

    # Req'd for i18n tools
    gettext
)

### FUNCTIONS

network_detection() {
  # Network Detection
  #
  # Make an HTTP request to google.com to determine if outside access is available
  # to us. If 3 attempts with a timeout of 5 seconds are not successful, then we'll
  # skip a few things further in provisioning rather than create a bunch of errors.
  if [[ "$(wget --tries=3 --timeout=5 --spider http://google.com 2>&1 | grep 'connected')" ]]; then
    echo "Network connection detected..."
    ping_result="Connected"
  else
    echo "Network connection not detected. Unable to reach google.com..."
    ping_result="Not Connected"
  fi
}

network_check() {
  network_detection
  if [[ ! "$ping_result" == "Connected" ]]; then
    echo -e "\nNo network connection available, skipping package installation"
    exit 0
  fi
}

noroot() {
  sudo -EH -u "vagrant" "$@";
}

profile_setup() {
  # Copy custom dotfiles and bin file for the vagrant user from local
  cp "/srv/config/bash_profile" "/home/vagrant/.bash_profile"
  # cp "/srv/config/bash_aliases" "/home/vagrant/.bash_aliases"
  # cp "/srv/config/vimrc" "/home/vagrant/.vimrc"
  #
  # if [[ ! -d "/home/vagrant/.subversion" ]]; then
  #   mkdir "/home/vagrant/.subversion"
  # fi
  #
  # cp "/srv/config/subversion-servers" "/home/vagrant/.subversion/servers"

  if [[ ! -d "/home/vagrant/bin" ]]; then
    mkdir "/home/vagrant/bin"
  fi

  rsync -rvzh --delete "/srv/config/homebin/" "/home/vagrant/bin/"
  chmod +x /home/vagrant/bin/*

  echo " * Copied /srv/config/bash_profile                      to /home/vagrant/.bash_profile"
  # echo " * Copied /srv/config/bash_aliases                      to /home/vagrant/.bash_aliases"
  # echo " * Copied /srv/config/vimrc                             to /home/vagrant/.vimrc"
  # echo " * Copied /srv/config/subversion-servers                to /home/vagrant/.subversion/servers"
  echo " * rsync'd /srv/config/homebin                          to /home/vagrant/bin"

  # If a bash_prompt file exists in the VVV config/ directory, copy to the VM.
  if [[ -f "/srv/config/bash_prompt" ]]; then
    cp "/srv/config/bash_prompt" "/home/vagrant/.bash_prompt"
    echo " * Copied /srv/config/bash_prompt to /home/vagrant/.bash_prompt"
  fi
}

package_check() {
  # Loop through each of our packages that should be installed on the system. If
  # not yet installed, it should be added to the array of packages to install.
  local pkg
  local package_version

  for pkg in "${apt_package_check_list[@]}"; do
    package_version=$(dpkg -s "${pkg}" 2>&1 | grep 'Version:' | cut -d " " -f 2)
    if [[ -n "${package_version}" ]]; then
      space_count="$(expr 20 - "${#pkg}")" #11
      pack_space_count="$(expr 30 - "${#package_version}")"
      real_space="$(expr ${space_count} + ${pack_space_count} + ${#package_version})"
      printf " * $pkg %${real_space}.${#package_version}s ${package_version}\n"
    else
      echo " *" $pkg [not installed]
      apt_package_install_list+=($pkg)
    fi
  done
}

package_install() {
  package_check

  # MySQL
  #
  # Use debconf-set-selections to specify the default password for the root MySQL
  # account. This runs on every provision, even if MySQL has been installed. If
  # MySQL is already installed, it will not affect anything.
  echo mysql-server mysql-server/root_password password "root" | debconf-set-selections
  echo mysql-server mysql-server/root_password_again password "root" | debconf-set-selections

  # Postfix
  #
  # Use debconf-set-selections to specify the selections in the postfix setup. Set
  # up as an 'Internet Site' with the host name 'vvv'. Note that if your current
  # Internet connection does not allow communication over port 25, you will not be
  # able to send mail, even with postfix installed.
  # echo postfix postfix/main_mailer_type select Internet Site | debconf-set-selections
  # echo postfix postfix/mailname string vvv | debconf-set-selections

  # Disable ipv6 as some ISPs/mail servers have problems with it
  # echo "inet_protocols = ipv4" >> "/etc/postfix/main.cf"

  # Provide our custom apt sources before running `apt-get update`
  # ln -sf /srv/config/apt-source-append.list /etc/apt/sources.list.d/vvv-sources.list
  # echo "Linked custom apt sources"

  if [[ ${#apt_package_install_list[@]} = 0 ]]; then
    echo -e "No apt packages to install.\n"
  else
    # Before running `apt-get update`, we should add the public keys for
    # the packages that we are installing from non standard sources via
    # our appended apt source.list

    # Retrieve the Nginx signing key from nginx.org
    echo "Applying Nginx signing key..."
    wget --quiet "http://nginx.org/keys/nginx_signing.key" -O- | apt-key add -

    # Apply the nodejs assigning key
    apt-key adv --quiet --keyserver "hkp://keyserver.ubuntu.com:80" --recv-key C7917B12 2>&1 | grep "gpg:"
    apt-key export C7917B12 | apt-key add -

    # Update all of the package references before installing anything
    echo "Running apt-get update..."
    apt-get update -y

    # Install required packages
    echo "Installing apt-get packages..."
    apt-get install -y ${apt_package_install_list[@]}

    # Clean up apt caches
    apt-get clean
  fi
}

tools_install() {
  # npm
  #
  # Make sure we have the latest npm version and the update checker module
  # npm install -g npm
  # npm install -g npm-check-updates

  # xdebug
  #
  # XDebug 2.2.3 is provided with the Ubuntu install by default. The PECL
  # installation allows us to use a later version. Not specifying a version
  # will load the latest stable.
  pecl install xdebug

  # # ack-grep
  # #
  # # Install ack-rep directory from the version hosted at beyondgrep.com as the
  # # PPAs for Ubuntu Precise are not available yet.
  # if [[ -f /usr/bin/ack ]]; then
  #   echo "ack-grep already installed"
  # else
  #   echo "Installing ack-grep as ack"
  #   curl -s http://beyondgrep.com/ack-2.14-single-file > "/usr/bin/ack" && chmod +x "/usr/bin/ack"
  # fi

  # COMPOSER
  #
  # Install Composer if it is not yet available.
  if [[ ! -n "$(composer --version --no-ansi | grep 'Composer version')" ]]; then
    echo "Installing Composer..."
    curl -sS "https://getcomposer.org/installer" | php
    chmod +x "composer.phar"
    mv "composer.phar" "/usr/local/bin/composer"
  fi

  if [[ -f /vagrant/provision/github.token ]]; then
    ghtoken=`cat /vagrant/provision/github.token`
    composer config --global github-oauth.github.com $ghtoken
    echo "Your personal GitHub token is set for Composer."
  fi

  # Grunt
  #
  # Install or Update Grunt based on current state.  Updates are direct
  # from NPM
  # if [[ "$(grunt --version)" ]]; then
  #   echo "Updating Grunt CLI"
  #   npm update -g grunt-cli &>/dev/null
  #   npm update -g grunt-sass &>/dev/null
  #   npm update -g grunt-cssjanus &>/dev/null
  #   npm update -g grunt-rtlcss &>/dev/null
  # else
  #   echo "Installing Grunt CLI"
  #   npm install -g grunt-cli &>/dev/null
  #   npm install -g grunt-sass &>/dev/null
  #   npm install -g grunt-cssjanus &>/dev/null
  #   npm install -g grunt-rtlcss &>/dev/null
  # fi
}

nginx_setup() {
  # Create an SSL key and certificate for HTTPS support.
  if [[ ! -e /etc/nginx/server.key ]]; then
	  echo "Generate Nginx server private key..."
	  vvvgenrsa="$(openssl genrsa -out /etc/nginx/server.key 2048 2>&1)"
	  echo "$vvvgenrsa"
  fi
  if [[ ! -e /etc/nginx/server.crt ]]; then
	  echo "Sign the certificate using the above private key..."
	  vvvsigncert="$(openssl req -new -x509 \
            -key /etc/nginx/server.key \
            -out /etc/nginx/server.crt \
            -days 3650 \
            -subj /CN=*.devm01.dev 2>&1)"
	  echo "$vvvsigncert"
  fi

  echo -e "\nSetup configuration files..."

  # Used to ensure proper services are started on `vagrant up`
  cp "/srv/config/init/start.conf" "/etc/init/start.conf"
  echo " * Copied /srv/config/init/start.conf               to /etc/init/start.conf"

  # Copy nginx configuration from local
  cp "/srv/config/nginx-config/nginx.conf" "/etc/nginx/nginx.conf"
  cp "/srv/config/nginx-config/nginx-wp-common.conf" "/etc/nginx/nginx-wp-common.conf"
  if [[ ! -d "/etc/nginx/custom-sites" ]]; then
    mkdir "/etc/nginx/custom-sites/"
  fi
  rsync -rvzh --delete "/srv/config/nginx-config/sites/" "/etc/nginx/custom-sites/"

  echo " * Copied /srv/config/nginx-config/nginx.conf           to /etc/nginx/nginx.conf"
  echo " * Copied /srv/config/nginx-config/nginx-wp-common.conf           to /etc/nginx/nginx-wp-common.conf"
  echo " * Rsync'd /srv/config/nginx-config/sites/              to /etc/nginx/custom-sites"
}

phpfpm_setup() {
  # Copy php-fpm configuration from local
  cp "/srv/config/php5-fpm-config/php5-fpm.conf" "/etc/php5/fpm/php5-fpm.conf"
  cp "/srv/config/php5-fpm-config/www.conf" "/etc/php5/fpm/pool.d/www.conf"
  cp "/srv/config/php5-fpm-config/php-custom.ini" "/etc/php5/fpm/conf.d/php-custom.ini"
  cp "/srv/config/php5-fpm-config/opcache.ini" "/etc/php5/fpm/conf.d/opcache.ini"
  cp "/srv/config/php5-fpm-config/xdebug.ini" "/etc/php5/mods-available/xdebug.ini"

  # Find the path to Xdebug and prepend it to xdebug.ini
  XDEBUG_PATH=$( find /usr -name 'xdebug.so' | head -1 )
  sed -i "1izend_extension=\"$XDEBUG_PATH\"" "/etc/php5/mods-available/xdebug.ini"

  echo " * Copied /srv/config/php5-fpm-config/php5-fpm.conf     to /etc/php5/fpm/php5-fpm.conf"
  echo " * Copied /srv/config/php5-fpm-config/www.conf          to /etc/php5/fpm/pool.d/www.conf"
  echo " * Copied /srv/config/php5-fpm-config/php-custom.ini    to /etc/php5/fpm/conf.d/php-custom.ini"
  echo " * Copied /srv/config/php5-fpm-config/opcache.ini       to /etc/php5/fpm/conf.d/opcache.ini"
  echo " * Copied /srv/config/php5-fpm-config/xdebug.ini        to /etc/php5/mods-available/xdebug.ini"
}

mysql_setup() {
  # If MySQL is installed, go through the various imports and service tasks.
  local exists_mysql

  exists_mysql="$(service mysql status)"
  if [[ "mysql: unrecognized service" != "${exists_mysql}" ]]; then
    echo -e "\nSetup MySQL configuration file links..."

    # Copy mysql configuration from local
    cp "/srv/config/mysql-config/my.cnf" "/etc/mysql/my.cnf"
    cp "/srv/config/mysql-config/root-my.cnf" "/home/vagrant/.my.cnf"

    echo " * Copied /srv/config/mysql-config/my.cnf               to /etc/mysql/my.cnf"
    echo " * Copied /srv/config/mysql-config/root-my.cnf          to /home/vagrant/.my.cnf"

    # MySQL gives us an error if we restart a non running service, which
    # happens after a `vagrant halt`. Check to see if it's running before
    # deciding whether to start or restart.
    if [[ "mysql stop/waiting" == "${exists_mysql}" ]]; then
      echo "service mysql start"
      service mysql start
      else
      echo "service mysql restart"
      service mysql restart
    fi

    # IMPORT SQL
    #
    # Create the databases (unique to system) that will be imported with
    # the mysqldump files located in database/backups/
    if [[ -f "/srv/db-mysql/init-custom.sql" ]]; then
      mysql -u "root" -p"root" < "/srv/db-mysql/init-custom.sql"
      echo -e "\nInitial custom MySQL scripting..."
    else
      echo -e "\nNo custom MySQL scripting found in db-mysql/init-custom.sql, skipping..."
    fi

    # Setup MySQL by importing an init file that creates necessary
    # users and databases that our vagrant setup relies on.
    mysql -u "root" -p"root" < "/srv/db-mysql/init.sql"
    echo "Initial MySQL prep..."

    # Process each mysqldump SQL file in database/backups to import
    # an initial data set for MySQL.
    "/home/vagrant/bin/db_import"
  else
    echo -e "\nMySQL is not installed. No databases imported."
  fi
}


services_restart() {
  # RESTART SERVICES
  #
  # Make sure the services we expect to be running are running.
  echo -e "\nRestart services..."
  service nginx restart

  # Disable PHP Xdebug module by default
  # php5dismod xdebug

  # Enable PHP mcrypt module by default
  # php5enmod mcrypt

  service php5-fpm restart

  # Add the vagrant user to the www-data group so that it has better access
  # to PHP and Nginx related files.
  usermod -a -G www-data vagrant
}

opcached_status(){
  # Checkout Opcache Status to provide a dashboard for viewing statistics
  # about PHP's built in opcache.
  if [[ ! -d "/srv/www/default/opcache-status" ]]; then
    echo -e "\nDownloading Opcache Status, see https://github.com/rlerdorf/opcache-status/"
    cd /srv/www/default
    git clone "https://github.com/rlerdorf/opcache-status.git" opcache-status
  else
    echo -e "\nUpdating Opcache Status"
    cd /srv/www/default/opcache-status
    git pull --rebase origin master
  fi
}

phpmyadmin_setup() {
  # Download phpMyAdmin
  if [[ ! -d /srv/www/default/database-admin ]]; then
    echo "Downloading phpMyAdmin..."
    cd /srv/www/default
    wget -q -O phpmyadmin.tar.gz "https://files.phpmyadmin.net/phpMyAdmin/4.4.10/phpMyAdmin-4.4.10-all-languages.tar.gz"
    tar -xf phpmyadmin.tar.gz
    mv phpMyAdmin-4.4.10-all-languages database-admin
    rm phpmyadmin.tar.gz
  else
    echo "PHPMyAdmin already installed."
  fi
  cp "/srv/config/phpmyadmin-config/config.inc.php" "/srv/www/default/database-admin/"
}

wp_cli() {
  # WP-CLI Install
  if [[ ! -d "/srv/www/wp-cli" ]]; then
    echo -e "\nDownloading wp-cli, see http://wp-cli.org"
    git clone "https://github.com/wp-cli/wp-cli.git" "/srv/www/wp-cli"
    cd /srv/www/wp-cli
    composer install
  else
    echo -e "\nUpdating wp-cli..."
    cd /srv/www/wp-cli
    git pull --rebase origin master
    composer update
  fi
  # Link `wp` to the `/usr/local/bin` directory
  ln -sf "/srv/www/wp-cli/bin/wp" "/usr/local/bin/wp"
}

wordpress_default() {
  # Install and configure the latest stable version of WordPress
  if [[ ! -d "/srv/www/wordpress-default" ]]; then
    echo "Downloading WordPress Stable, see http://wordpress.org/"
    cd /srv/www/
    curl -L -O "https://wordpress.org/latest.tar.gz"
    noroot tar -xvf latest.tar.gz
    mv wordpress wordpress-default
    rm latest.tar.gz
    cd /srv/www/wordpress-default
    echo "Configuring WordPress Stable..."
    noroot wp core config --dbname=wordpress_default --dbuser=wp --dbpass=wp --quiet --extra-php <<PHP
// Match any requests made via xip.io.
if ( isset( \$_SERVER['HTTP_HOST'] ) && preg_match('/^(wordpress.devm01.)\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}(.xip.io)\z/', \$_SERVER['HTTP_HOST'] ) ) {
define( 'WP_HOME', 'http://' . \$_SERVER['HTTP_HOST'] );
define( 'WP_SITEURL', 'http://' . \$_SERVER['HTTP_HOST'] );
}
define( 'WP_DEBUG', true );
PHP
    echo "Installing WordPress Stable..."
    noroot wp core install --url=wordpress.devm01.dev --quiet --title="Local WordPress Dev" --admin_name=admin --admin_email="admin@devm01.dev" --admin_password="password"
  else
    echo "Updating WordPress Stable..."
    cd /srv/www/wordpress-default
    noroot wp core upgrade
  fi
}

# SCRIPT

network_check
# Profile_setup
echo "Bash profile setup and directories."
profile_setup

network_check
# Package and Tools Install
echo " "
echo "Main packages check and install."
package_install
tools_install
nginx_setup
phpfpm_setup
services_restart
mysql_setup

network_check

echo " "
echo "Installing/updating debugging tools"
opcached_status
phpmyadmin_setup
wp_cli
wordpress_default

#set +xv
# And it's done
end_seconds="$(date +%s)"
echo "-----------------------------"
echo "Provisioning complete in "$((${end_seconds} - ${start_seconds}))" seconds"
echo "For further setup instructions, visit http://devm01.dev"
