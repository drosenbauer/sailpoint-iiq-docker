#!/bin/bash

source bin/include/utils.sh

mkdir -p build

PLUGINS=()
PATCHES=()
HOTFIXES=()
TRUSTEDCERTS=()
OBJECTS=()

while getopts ":b:t:z:w:m:e:p:s:o:l:" opt; do
  case ${opt} in
    l ) LABEL=${OPTARG}
      ;;
    b ) SSB=${OPTARG}
      ;;
    t ) SPTARGET=${OPTARG}
      ;;
    z ) IIQ_ZIP=${OPTARG}
      ;;
    c )
      TRUSTEDCERTS+=("${OPTARG}")
      ;;
    m )
      PLUGINS+=("${OPTARG}")
      ;;
    p )
      PATCHES+=("${OPTARG}")
      ;;
    e )
      HOTFIXES+=("${OPTARG}")
      ;;
    o )
      OBJECTS+=("${OPTARG}")
      ;;
    s ) SKIP_DEMO_COMPANY_DATA=y
      ;;
    w ) IIQ_WAR=${OPTARG}
      ;;
    \? ) echo "Usage: ./start.sh [-b <existing SSB build directory>] [-t SPTARGET] [-z <identityIQ zip>] [-w <existing WAR file>]"
      ;;
  esac
done

if [[ ! -z $TAG ]]; then
	greenecho " => Using image tag ${LABEL}"
fi


# Validate WAR locator inputs
if [[ -z $SSB ]] && [[ -z $IIQ_ZIP ]] && [[ -z $IIQ_WAR ]]; then
	echo "You must specify an IIQ zip (-z), an IIQ war (-w), or an SSB build directory (-b)"
	exit 5
fi

# Validate incompatible inputs
if [[ ! -z $SSB ]] && [[ ! -z $IIQ_ZIP ]]; then
	echo "The zip (-z) and build (-b) options are mutually exclusive and you specified both"
	exit 5
fi

# Validate specified locations
if [[ ! -z "$IIQ_ZIP" ]] && [[ ! -e "$IIQ_ZIP" ]]; then
	redecho "IIQ zip file $IIQ_ZIP does not exist"
	exit 5
fi

if [[ ! -z $IIQ_WAR ]] && [[ ! -e $IIQ_WAR ]]; then
	redecho "IIQ war file $IIQ_WAR does not exist"
	exit 5
fi

for plugin in "${PLUGINS[@]}"
do
	if [[ ! -e $plugin ]]; then
		redecho "Cannot find plugin $plugin"
		exit 5
	fi
done

COMPOSE_PATH=$(which docker-compose)
if [[ ! -z $(echo "$COMPOSE_PATH" | grep "not found") ]]; then
	redecho "Cannot find the docker-compose command"
	exit 5
fi

greenecho " => Creating and cleaning build directory"
HERE=`pwd`
mkdir -p ${HERE}/build/tmp
BUILD="${HERE}/build"
if [ -e "${BUILD}/identityiq.war" ]; then
	rm "${BUILD}/identityiq.war"
fi

greenecho " => Build directory is ${BUILD}"

IIQ_VERSION=
IIQ_PATCH=

# Sanity checking for optional SSB build
if [[ ! -z $SSB ]]; then
	if [[ ! -z $(echo "${SSB}" | grep "git\\.") ]]; then
		greenecho " => SSB looks like a Git repo, checking it out to the 'build/tmp/ssb' folder..."
		pushd "${BUILD}/tmp"
		# This operation is expensive, see if the repo is the same as last time and don't delete if it is
		if [[ -e ./repo ]]; then
			OLDREPO=`cat ./repo`
			if [[ -e ssb ]] && [[ "${SSB}" != "${OLDREPO}" ]]; then
				# Refresh
				rm -rf ssb/*
				git clone "${SSB}" ssb
			else
				# Update
				pushd ssb
				git pull
				popd
			fi
		else
			# New
			git clone "${SSB}" ssb
		fi
		echo ${SSB} > ./repo
		SSB=${BUILD}/tmp/ssb
		popd
		greenecho " => SSB checked out from Git"
	fi
	SSB=${SSB%/}
	if [[ ! -f "${SSB}/build.xml" ]]; then
		redecho "Option -b directory '${SSB}' does not contain a build.xml"
		exit 1
	fi

	if [[ -z "${SPTARGET}" ]]; then
	        redecho " !! SSB specified but no SPTARGET defined; using 'sandbox' by default"
	        SPTARGET=sandbox
	fi

	BUILD_PROPERTIES=${SSB}/build.properties
	if [[ ! -e ${BUILD_PROPERTIES} ]]; then
		BUILD_PROPERTIES=${SSB}/${SPTARGET}.build.properties
		if [[ ! -e ${BUILD_PROPERTIES} ]]; then
			redecho "No build.properties or ${SPTARGET}.build.properties found"
			exit 1
		fi
	fi

	# This goofy construct is needed to compensate for DOS-formatted files with a \r in them
	IIQ_VERSION=`grep IIQVersion ${BUILD_PROPERTIES} | head -1 | awk -F "=" '{print $2}' | tr -d '\r'`
	IIQ_PATCHLEVEL=`grep IIQPatchLevel ${BUILD_PROPERTIES} | awk -F "=" '{print $2}' | tr -d '\r'`

	if [[ ! -z ${IIQ_PATCHLEVEL} ]]; then
		IIQ_PATCH="$IIQ_VERSION$IIQ_PATCHLEVEL"
		greenecho " => Identified IIQ patch $IIQ_PATCH"
	fi
fi

ANT=`which ant`
if [[ -z ${ANT} ]]; then
	redecho "The 'ant' executable is not available on your path"
	exit 2
fi

JAVA=`which java`
if [[ -z ${JAVA} ]]; then
	redecho "The 'java' executable is not available on your path"
	exit 3
fi

if [[ ! -z ${SSB} ]]; then
	greenecho " => SSB configuration -- "
	echo "   SSB build: ${SSB}/build.xml"
	echo "   SSB SPTARGET: ${SPTARGET}"
fi

if [[ ! -z $IIQ_ZIP ]]; then
	IIQ_ZIP=`realname "${IIQ_ZIP}"`
fi

# Start building
if [[ ! -z ${SSB} ]]; then
	greenecho " => Building SSB..."
	export SPTARGET
	pushd ${SSB}
	mkdir -p build
	ant clean war >> ${BUILD}/build.log 2>&1
	if [[ ! -e build/deploy/identityiq.war ]]; then
		redecho "The SSB build does not appear to have produced an identityiq.war; please see the build.log for details"
		exit 9
	fi
	cp build/deploy/identityiq.war ${BUILD} 2> /dev/null
	popd
else
	if [[ ! -z "$IIQ_ZIP" ]]; then
		greenecho " => No SSB; extracting WAR from identityiq ZIP file"
		pushd ${BUILD}
		unzip -qo "$IIQ_ZIP"
		popd
	else
		cp "${IIQ_WAR}" "${BUILD}/identityiq.war"
	fi
fi

if [[ ! -e ${BUILD}/identityiq.war ]]; then
	redecho "The build directory does not contain an identityiq.war"
	exit 9
fi

cp ${BUILD}/identityiq.war iiq-build/sailpoint/

mkdir -p iiq-build/src/patch
mkdir -p iiq-build/src/efix
mkdir -p iiq-build/src/plugins
mkdir -p iiq-build/src/certs
mkdir -p iiq-build/src/objects

rm -f iiq-build/src/plugins/*.zip
rm -f iiq-build/src/patch/*.jar
rm -f iiq-build/src/efix/*.zip
rm -f iiq-build/src/efix/*.jar
rm -rf iiq-build/src/objects/*

touch iiq-build/src/efix/.keep
touch iiq-build/src/patch/.keep
touch iiq-build/src/plugins/.keep
touch iiq-build/src/certs/.keep
touch iiq-build/src/objects/.keep

for patch in "${PATCHES[@]}"
do
	greenecho " => Including patch archive $patch"
	cp "$patch" "iiq-build/src/patch"
done

for efix in "${HOTFIXES[@]}"
do
	greenecho " => Including efix archive $efix"
	cp "$efix" "iiq-build/src/efix"
done

for plugin in "${PLUGINS[@]}"
do
	greenecho " => Including plugin archive $plugin"
	cp "$plugin" "iiq-build/src/plugins"
done

for cert in "${TRUSTEDCERTS[@]}"
do
	greenecho " => Including trusted SSL certificate $cert"
	cp "$cert" "iiq-build/src/certs"
done

for object in "${OBJECTS[@]}"
do
	greenecho " => Including object $object"
	cp -rf "$object" "iiq-build/src/objects"
done

greenecho " => Building Docker containers, please wait a minute or two..."
docker-compose --progress quiet build

if [[ ! -z "${LABEL}" ]]; then
	greenecho " => Tagging image 'latest' with $LABEL"
	docker tag git.identityworksllc.com:5005/idw/idw-sailpoint/sailpoint-docker:latest "git.identityworksllc.com:5005/idw/idw-sailpoint/sailpoint-docker:$LABEL"
fi

greenecho " => All done!"
