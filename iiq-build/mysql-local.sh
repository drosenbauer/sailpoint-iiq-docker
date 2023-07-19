#!/bin/bash

################
# This script installs and runs the mysqld server via 'apt', directly from the mysql
# apt repository. After installing, it invokes 'mysql-local-startup.sh' to do
# the initialization and startup.

export DEBIAN_FRONTEND=noninteractive

groupadd -r mysql && useradd -r -g mysql mysql

echo mysql-apt-config mysql-apt-config/enable-repo select mysql-8.0-dmr | debconf-set-selections
echo mysql-apt-config mysql-apt-config/select-server select mysql-8.0 | debconf-set-selections

# Yes, this does actually set the Mysql root password to 'password'
echo mysql-community-server mysql-community-server/root-pass password password | debconf-set-selections
echo mysql-community-server mysql-community-server/re-root-pass password password | debconf-set-selections

wget https://dev.mysql.com/get/mysql-apt-config_0.8.26-1_all.deb

apt-get update
apt-get install -y lsb-release sudo dirmngr

dpkg -i mysql-apt-config_0.8.26-1_all.deb

apt-key adv --keyserver keyserver.ubuntu.com --recv-keys 467B942D3A79BD29

apt-get update
apt-get install -y mysql-server

# This stuff is all from the default MySQL Docker install

mkdir -p /home/mysql

rm -rf /var/lib/mysql && mkdir -p /var/lib/mysql /var/run/mysqld
chown -R mysql:mysql /var/lib/mysql /var/run/mysqld /home/mysql
chmod 777 /var/run/mysqld /var/lib/mysql

mkdir -p /etc/mysql
mkdir -p /docker-entrypoint-initdb.d/

echo "Starting up mysqld"

sudo -u mysql bash /mysql-local-startup.sh mysqld --wait-timeout=28800
