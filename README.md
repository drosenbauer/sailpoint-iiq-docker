Quick Start
===========

# Single container

1.  Install Docker and Docker Compose.
2.  Obtain an IdentityIQ zip file from [Compass Downloads](https://community.sailpoint.com/t5/IdentityIQ-Downloads/ct-p/IIQ_downloads).
3.  `git clone <this repo>`
4.  `cd sailpoint-docker`
5.  `./build.sh -z /path/to/identityiq-7.3.zip`

The image tagged `identityworksllc/sailpoint-iiq:latest` can be started standalone using the following Docker command:

    docker run -it -eDATABASE_TYPE=local -p8080:8080 -d identityworksllc/sailpoint-iiq:latest

Note that in local mode, the startup script will install and configure MySQL as part of container startup, rather than at built time, so your container will need network access.

# Compose (recommended)

On a Linux or Linux-like infrastructure:

1.  Install Docker and Docker Compose.
2.  Obtain an IdentityIQ zip file from [Compass Downloads](https://community.sailpoint.com/t5/IdentityIQ-Downloads/ct-p/IIQ_downloads).
3.  `git clone <this repo>`
4.  `cd sailpoint-docker`
5.  `./build.sh -z /path/to/identityiq-7.3.zip`
6.  Start up a standalone stack with `docker-compose up -d`.

IIQ will now be available on port 8080.

## Initialization container

A container called `iiq-init` will run on startup in the default configuration. This is a transient *init container*, which will do all of the database configuration and import of artifacts, then exit. All other IIQ containers will wait for the init container to finish before starting.

## Scaling

To scale IIQ, use a docker-compose command like `docker-compose up -d --scale iiq=3`, which will start 3 IIQ nodes. The IIQ instances will name their Server objects `iiq1`, `iiq2`, etc, but this does not necessarily correspond to the replica labeling (`iiq_2`) in Docker.

You can also scale at runtime using the same command after startup, which will add or remove nodes as needed. Note that the nodes added and removed are decided by Docker, not by their startup order or counter ID. This means that on scaling down, you may lose `iiq1` but keep `iiq2`.

# Swarm

If you would like to run in Swarm Mode, you will need to make a couple changes to the Compose file:

1.  Uncomment the section under service `loadbalancer` indicated in a comment.
2.  Move all `labels:` tags under a `deploy:` tag.

If you are interested in Swarm, I trust that you otherwise know what you're doing.

Usage
=====

# Building

On initial download, you will need to build the images in your local Docker environment. 

## With the provided build script

You must specify a way to obtain an identityiq.war using one of three flags:

* `-z`: A local identityiq-7.x.zip
* `-b`: An SSB build folder (or Git repository), which must contain a build.xml
* `-w`: An already-built WAR file

The WAR file will be staged to `iiq-build/src/identityiq.war`. 

Once everything is staged, the build script will build the Docker images.

Additional parameters:

* `-p`: Specify the path to a JAR file for a major patch, such as 7.3p2
* `-e`: Specify the path to an e-fix archive
* `-m`: Specify the patch to a plugin archive (think "m" for "module")
* `-t`: If you specify an SSB build, this value will be given as SPTARGET
* `-c`: Specify the path to a trusted certificate that will be imported into the Java keystore

You can specify multiple plugins, e-fixes, and trusted certificates by repeating the option, such as `./build.sh -m plugin1.zip -m plugin2.zip`.

If you specify an SSB build, you do not need to specify any patches or hotfixes, since these are included in the build.

## Manually 

If you want to do it yourself or use a custom build, you can copy a WAR file to `iiq-build/src` manually and then invoke `docker-compose build`. This is ultimately what the build script  is doing behind the scenes.

# Additional scripts

Additional scripts are provided in the `bin` directory.

## Output

To follow the logs, a `tail.sh` script has been provided.

## Entering the shell

You can enter the shell of any of the running containers using the provided `enter-shell.sh` script. 

By default, with no parameters, you will enter the primary iiq-master container. You can specify a WHICH environment variable to enter another. For example: `WHICH=iiq-secondary ./enter-shell.sh`

## Stopping

To stop the stack, run `docker-compose down`.

SSB
===

If you use the `-b` flag to the startup script, your SSB project will be built using `ant clean war`. The WAR file will be provided to the container and startup will proceed normally. Since the schema is regenerated before import, no special action is needed for extended attributes or patches.

## Git integration

If the value passed to `-b` looks like a git repository, the whole SSB build will be pulled from Git before build.

Pulling an entire SSB build from Git can take forever. The script tracks the most recent value passed to `-b`, and if the repository is the same as last time, it does not do a `clone` but instead a `pull`.

Database
========

By default, the Compose stack uses is Microsoft's `mssql:latest` image. This is free for use in non-Production environments. The SA password is available in `docker-compose.yml`. 

To switch to MySQL, you can change the `DATABASE_TYPE` environment variable in the compose file to `mysql`. The startup script will run appropriate database installation commands depending on the type you specify.

If you start up a standalone container and a `DATABASE_TYPE` of `local`, an MySQL database will be installed in the IIQ container on startup.

Services
========

This Docker Compose file will start up several services:

* db_mysql: MySQL 5.7
* db: The latest MSSQL developer image
* mail: MailHog
* ldap: OpenLDAP
* ssh: An SSH server
* loadbalancer: The load balancer Traefik
* iiq: IdentityIQ nodes (which can be replicated ad nauseum)
* counter and done: Utility services to assist with startup of the stateful IIQ services

These should be sufficient to demonstrate most of the non-proprietary connectors in IIQ. The service names double as the hostnames from within the containers, so IIQ sees the database host as having DNS name `db`, LDAP as having the DNS name `ldap`, etc. 

Default usernames and passwords are available in the `docker-compose.yml` file.

Active Directory and other Windows connectors will require using a Windows installation. The IQService does run in Mono but the user management APIs required for these connectors are not present outside of Windows.

Load balancer
=============

The load balancer [Traefik](https://traefik.io/) is used to forward traffic to one or more backend IIQ hosts. It is granted access to the Docker socket which essentially gives it "root" access to your Docker environment. It will monitor containers as they start and forward traffic among them automatically. It is configured for sticky sessions by default, as IIQ requires. Once the stack is started, you can access the Traefik dashboard at `http://localhost:28080`.

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
