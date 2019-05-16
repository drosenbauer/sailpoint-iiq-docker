#!/bin/bash

export DEBIAN_FRONTEND=noninteractive

echo mysql-apt-config mysql-apt-config/enable-repo select mysql-5.7-dmr | debconf-set-selections
echo mysql-apt-config mysql-apt-config/select-server select mysql-5.7 | debconf-set-selections

# Yes, this does actually set the Mysql root password to 'password'
echo mysql-community-server mysql-community-server/root-pass password password | debconf-set-selections
echo mysql-community-server mysql-community-server/re-root-pass password password | debconf-set-selections

wget https://dev.mysql.com/get/mysql-apt-config_0.8.13-1_all.deb

apt-get update
apt-get install -y lsb-release sudo

dpkg -i mysql-apt-config_0.8.13-1_all.deb

apt-get update
apt-get install -y mysql-server

# This stuff is all from the default MySQL Docker install

find /etc/mysql/ -name '*.cnf' -print0 \
        | xargs -0 grep -lZE '^(bind-address|log)' \
        | xargs -rt -0 sed -Ei 's/^(bind-address|log)/#&/'

echo '[mysqld]\nskip-host-cache\nskip-name-resolve' > /etc/mysql/conf.d/docker.cnf

rm -rf /var/lib/mysql && mkdir -p /var/lib/mysql /var/run/mysqld
chown -R mysql:mysql /var/lib/mysql /var/run/mysqld
chmod 777 /var/run/mysqld

echo "Starting up mysqld"

sudo -u mysql bash /mysql-local-startup.sh mysqld --wait-timeout=28800
