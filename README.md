Quick Start
===========

# Compose

On a Linux or Linux-like infrastructure:

1.  Install Docker and Docker Compose.
2.  Obtain an IdentityIQ zip file from [Compass Downloads](https://community.sailpoint.com/community/identityiq/downloads).
3.  `git clone <this repo>`
4.  `cd sailpoint-docker`
5.  `./build.sh -z /path/to/identityiq-7.3.zip`
6.  Start up a standalone stack with `docker-compose up -d`.

IIQ will now be available on port 8080.

# Swarm

If you would like to run in Swarm Mode, you will need to make a couple changes to the Compose file:

1.  Uncomment the section under service `lb2` indicated in a comment.
2.  Move all `labels:` tags under a `deploy:` tag.

If you are interested in Swarm, I trust that you otherwise know what you're doing.

Usage
=====

# Building

On initial download, you will need to build the images in your local Docker environment. 

## With the provided build script

You must specify the location of an IdentityIQ WAR using one of three flags:

* `-z`: A local identityiq-7.x.zip
* `-b`: An SSB build folder (or Git repository), which must contain a build.xml
* `-w`: An already-built WAR file

The WAR file will be copied to `iiq-build/src/identityiq.war`. 

Once everything is staged, the build script will build the Docker images.

## Manually 

Of course, you can copy a WAR file there manually and then invoke `docker-compose build` yourself.

# Additional scripts

Additional scripts are provided in the `bin` directory.

## Output

To follow the logs, a `tail.sh` script has been provided.

## Entering the shell

You can enter the shell of any of the running containers using the provided `enter-shell.sh` script. 

By default, with no parameters, you will enter the primary iiq-master container. You can specify a WHICH environment variable to enter another. For example: `WHICH=iiq-secondary ./enter-shell.sh`

## Stopping

To stop the container, use `./stop.sh`.

SSB
===

If you use the `-b` flag to the startup script, your SSB project will be built using `ant clean war`. The WAR file will be provided to the container. The container startup script will do the following before starting Tomcat:

* Unzip everything to the Tomcat webapps directory
* Generate a custom schema using `iiq schema`
* Create the plugin database (and user) with password `identityiq`
* Import the overall schema into the datbase using the `mysql` command
* Import any patch SQL files in Unix `sort` order
* Run the `iiq patch` command, if a minor patch is specified
* Import `init.xml` using the `iiq console` (which includes customizations)
* Import `init-lcm.xml` using the `iiq console`

This is roughly equivalent to `ant clean main createdb extenddb import-stock import-lcm patchdb runUpgrade import-custom dist` in the SSB build.

## Git integration

If the value passed to `-b` looks like a git repository, the whole SSB build will be pulled from Git before build.

Pulling an entire SSB build from Git can take forever. The script tracks the most recent value passed to `-b`, and if the repository is the same as last time, it does not do a `clone` but instead a `pull`.

Database
========

By default, the Compose stack uses is Microsoft's `mssql:latest` image. This is free for use in non-Production environments. The SA password is available in `docker-compose.yml`. 

To switch to MySQL, you can change the `DATABASE_TYPE` environment variable in the compose file to `mysql`. The startup script will run appropriate database installation commands depending on the type you specify.

Services
========

This Docker Compose file will start up several services:

* db_mysql: MySQL 5.7
* db: The latest MSSQL developer image
* mail: MailHog
* ldap: OpenLDAP
* ssh: An SSH server
* lb2: The load balancer Traefik
* iiq-master: IdentityIQ primary node

These should be sufficient to demonstrate most of the non-proprietary connectors in IIQ. The service names double as the hostnames from within the containers, so IIQ sees the database host as having DNS name `db`, LDAP as having the DNS name `ldap`, etc. 

Default usernames and passwords are available in the `docker-compose.yml` file.

Active Directory and other Windows connectors will require using a Windows installation. The IQService does run in Mono but the user management APIs required for these connectors are not present outside of Windows.

Load balancer
=============

The load balancer [Traefik](https://traefik.io/) is used to forward traffic to one or more backend IIQ hosts. It is granted access to the Docker socket which essentially gives it "root" access to your Docker environment. It will monitor containers as they start and forward traffic among them automatically. It is configured for sticky sessions by default, as IIQ requires. Once the stack is started, you can access the Traefik dashboard at `http://localhost:28080`.

Traefik runs in Swarm mode. If you choose to start up a single-node stack using `docker-compose up`, Traefik will not be able to listen to your Docker stack, so you will need to use port 8880 to access Tomcat directly.

SERI
====

If `WEB-INF/config/seri` is detected by the startup script, the SERI init objects will be imported automatically. 

Additionally, you will be able to use the `seri.sh` script to more easily push in any SERI component after IIQ is started. If the component is in the folder `config/seri/catalog/UseCase-XYZ`, you would specify `UseCase-XYZ` as the parameter to `seri.sh`. The `setup.xml` file in that folder will be imported. If the folder you specify begins with *Plugin*, the contents will be imported as one or more plugins instead.

Accelerator Pack
================

If the IIQ Accelerator Pack is detected via the XML file `WEB-INF/config/init-acceleratorpack.xml`, it will be automatically imported.

Acknowledgement
===============

This codebase is inspired by and partially derived from the sailpoint-iiq Docker project by [Steffen Sperling](https://community.sailpoint.com/people/ssperling): https://github.com/steffensperling/sailpoint-iiq
