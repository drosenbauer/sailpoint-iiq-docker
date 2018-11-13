Usage
=====

# Building

On initial download, you will need to build the images in your local Docker environment. Just run `docker-compose build` in the main project directory.

# Starting

A startup script, `start.sh`, has provided to give you numerous options. 

You must provide the location of an IdentityIQ WAR using one of three flags:

* `-z`: A local identityiq-7.x.zip
* `-b`: An SSB build folder (or Git repository), which must contain a build.xml
* `-w`: An already-built WAR file

In whatever method you specify (apart from a local SSB), an `identityiq.war` will eventually be copied to the `build` subfolder for staging and then mounted into the running Docker container.

If you want to start a cluster with a primary and a secondary node, use the `start-cluster.sh` script instead. All other parameters are the same. The other scripts will remember which you used to provide appropriate output.

## Example startup output

    host:pub-sailpoint-docker devin$ ./start-cluster.sh -z identityiq-7.3.zip
     => Creating and cleaning build directory
     => Build directory is /Users/devin/code/docker/docker-sailpoint/pub-sailpoint-docker/build
     => Dump configuration
       Compose file: docker-compose-cluster.yml
     => No SSB; extracting WAR from identityiq ZIP file
     => Creating .env file for Docker
      SPTARGET=
      IIQ_WAR=/Users/devin/code/docker/docker-sailpoint/pub-sailpoint-docker/build/identityiq.war
      LISTEN_PORT=8080
      SSB=
      IIQ_PATCH=
      SKIP_DEMO_COMPANY_DATA=
      IIQ_IMPORTS=/Users/devin/code/docker/docker-sailpoint/pub-sailpoint-docker/build/imports
      IIQ_AUTO_IMPORTS=/Users/devin/code/docker/docker-sailpoint/pub-sailpoint-docker/build/import-list
     => Starting Docker...
    Creating network "iiq_default" with the default driver
    Creating iiq_lb2_1  ... done
    Creating iiq_ldap_1 ... done
    Creating iiq_ssh_1  ... done
    Creating iiq_db_1   ... done
    Creating iiq_mail_1 ... done
    Creating iiq_iiq-master_1 ... done
    Creating iiq_iiq-secondary_1 ... done

## Containers

The containers will be started in `-d` (daemon) mode, which runs them in the background.

You can use the `status.sh` script to check the status of the running environment.

It will take 2-3 minutes for IIQ to become available once `start.sh` completes. You'll be able to access your IIQ installation at `http://localhost:8080` with the usual default username and password.

## Git integration

If the value passed to `-b` looks like a git repository, the whole SSB build will be pulled from Git before build.

Pulling an entire SSB build from Git can take forever. The script tracks the most recent value passed to `-b`, and if the repository is the same as last time, it does not do a `clone` but instead a `pull`.

## Automatically importing (apart from SSB)

Anything placed into the `./build/imports/` directory will be copied to IIQ's `config` directory, retaining folder structure. If you want to automatically import anything, you can list it in a text file, `./build/import-list`, one item per line. Both the folder and file will be created by `start.sh` on first run if they are missing, as they must be mounted into Docker.

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

Services
========

This Docker Compose file will start up six services in six containers:

* db: MySQL 5.7
* mail: MailHog
* ldap: OpenLDAP
* ssh: An SSH server
* lb: An HAProxy load balancer with sticky sessions based on JSESSIONID
* iiq1: IdentityIQ primary node

These should be sufficient to demonstrate most of the non-proprietary connectors in IIQ. The service names double as the hostnames from within the containers, so IIQ sees the database host as having DNS name `db`, LDAP as having the DNS name `ldap`, etc. 

Default usernames and passwords are available in the `docker-compose.yml` file.

Load balancer
=============

The load balancer [Traefik](https://traefik.io/) is used to forward traffic to one or more backend IIQ hosts. It is granted access to the Docker socket which essentially gives it "root" access to your Docker environment. It will monitor containers as they start and forward traffic among them automatically. It is configured for sticky sessions by default, as IIQ requires.

Once the stack is started, you can access the Traefik dashboard at `http://localhost:28080`.

SERI
====

If a folder called `config/seri` is detected by the startup script, the SERI init objects will be imported automatically. 

Additionally, you will be able to use the `seri.sh` script to more easily push in any SERI component after IIQ is started. If the component is in the folder `config/seri/catalog/UseCase-XYZ`, you would specify `UseCase-XYZ` as the parameter to `seri.sh`. The `setup.xml` file in that folder will be imported. If the folder you specify begins with *Plugin*, the contents will be imported as one or more plugins instead.

Procedurally generated HR Data
==============================

By default, a demonstration set of HR data is imported into the MySQL database to `hr.hr_people`. SELECT access to this table is granted to the `identityiq` user.

All data is procedurally generated by a program developed at IDW. No record is intended to resemble any real-life individuals.

# Description of the data

This data represents an imaginary medium-sized grocery store corporation.

Requirements used by the generator follow:

* There are around 33,000 full and part time employees.
* There are two affiliate companies (Primary Grocers Inc and Affiliate Grocers Inc) which have separate manager hierarchies and locations. 
* A few people may have a record at more than one company. For example, Jim worked as a cashier at Affiliate then quit, then later took a job at Primary. 
* Users will have no more than one record per company.
* The manager hierarchy is a consistent tree with multiple layers of managers depending on department size. Managers are mapped by employee number.
* The full assortment of employment situations is represented: pre-hire, current employee, terminated, rehired.
* A small subset of users are current employees on leave (status `L`).

The `employee_number` field is intended as the unique ID.

# Fake SSNs

The dataset includes an `ssn` field with SSN-formatted randomly generated values. These values begin with 9xx so are not valid SSNs. This field is intended for demonstrating or practicing PII management.

# Additional datasets

Additional larger or smaller ramdomly generated user sets are available on request. 

We also have generated university datasets with users having multiple valid affiliations.

Acknowledgement
===============

This codebase is inspired by and partially derived from the sailpoint-iiq Docker project by [Steffen Sperling](https://community.sailpoint.com/people/ssperling): https://github.com/steffensperling/sailpoint-iiq