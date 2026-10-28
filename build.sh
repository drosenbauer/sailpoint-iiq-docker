#!/bin/bash

source bin/include/utils.sh

SECONDS=0
ui_intro "IdentityIQ Docker build"

mkdir -p build

PLUGINS=()
PATCHES=()
HOTFIXES=()
TRUSTEDCERTS=()
OBJECTS=()

usage() {
	ui_section "Usage"
	ui_kv "-z" "IdentityIQ distribution zip"
	ui_kv "-w" "Existing identityiq.war"
	ui_kv "-b" "SSB build directory or Git repository"
	ui_kv "-t" "SSB SPTARGET (default: sandbox)"
	ui_kv "-p" "Patch jar (repeatable)"
	ui_kv "-e" "Efix archive (repeatable)"
	ui_kv "-m" "Plugin zip (repeatable)"
	ui_kv "-o" "Objects file or directory (repeatable)"
	ui_kv "-c" "Trusted certificate (repeatable)"
	ui_kv "-l" "Image label"
	ui_kv "-s" "Skip demo company data"
}

# Comma-separated file names of the given paths
names() {
	local out="" f
	for f in "$@"; do
		out+="${out:+, }$(basename "$f")"
	done
	printf '%s' "$out"
}

# These run under ui_run, i.e. in a subshell, so they can cd freely
checkout_ssb() {
	cd "${BUILD}/tmp" || return 1
	# This operation is expensive, see if the repo is the same as last time and don't delete if it is
	if [[ -e ./repo ]]; then
		OLDREPO=`cat ./repo`
		if [[ -e ssb ]] && [[ "${SSB}" != "${OLDREPO}" ]]; then
			# Refresh
			rm -rf ssb/*
			git clone "${SSB}" ssb || return 1
		else
			# Update
			cd ssb && git pull
		fi
	else
		# New
		git clone "${SSB}" ssb || return 1
	fi
	echo "${SSB}" > "${BUILD}/tmp/repo"
}

build_ssb() {
	cd "${SSB}" && mkdir -p build && ant clean war
}

extract_zip() {
	cd "${BUILD}" || return 1
	unzip -qo "$IIQ_ZIP"
	# Exit code 1 is only a warning
	[[ "$?" -le 1 ]]
}

while getopts ":b:t:z:w:m:e:p:s:o:l:c:" opt; do
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
    \? ) ui_err "Unknown option -${OPTARG}"
      usage
      ui_die 5 "Invalid usage"
      ;;
    : ) ui_die 5 "Option -${OPTARG} requires an argument"
      ;;
  esac
done

# Validate WAR locator inputs
if [[ -z "$SSB" ]] && [[ -z "$IIQ_ZIP" ]] && [[ -z "$IIQ_WAR" ]]; then
	ui_err "You must specify an IIQ zip (-z), an IIQ war (-w), or an SSB build directory (-b)"
	usage
	ui_die 5 "Nothing to build"
fi

# Validate incompatible inputs
if [[ ! -z "$SSB" ]] && [[ ! -z "$IIQ_ZIP" ]]; then
	ui_die 5 "The zip (-z) and build (-b) options are mutually exclusive and you specified both"
fi

# Validate specified locations
if [[ ! -z "$IIQ_ZIP" ]] && [[ ! -e "$IIQ_ZIP" ]]; then
	ui_die 5 "IIQ zip file $IIQ_ZIP does not exist"
fi

if [[ ! -z "$IIQ_WAR" ]] && [[ ! -e "$IIQ_WAR" ]]; then
	ui_die 5 "IIQ war file $IIQ_WAR does not exist"
fi

for plugin in "${PLUGINS[@]}"
do
	if [[ ! -e "$plugin" ]]; then
		ui_die 5 "Cannot find plugin $plugin"
	fi
done

if ! docker compose version > /dev/null 2>&1; then
	ui_die 5 "Cannot find the 'docker compose' command"
fi

if [[ ! -z "${SSB}" ]] && [[ -z "${SPTARGET}" ]]; then
	ui_warn "SSB specified but no SPTARGET defined; using 'sandbox' by default"
	SPTARGET=sandbox
fi

ui_section "Configuration"
if [[ ! -z "${SSB}" ]]; then
	ui_kv "Source" "SSB build ${SSB}"
	ui_kv "Target" "${SPTARGET}"
elif [[ ! -z "${IIQ_ZIP}" ]]; then
	ui_kv "Source" "IIQ zip $(basename "${IIQ_ZIP}")"
else
	ui_kv "Source" "IIQ war $(basename "${IIQ_WAR}")"
fi
[[ ${#PATCHES[@]} -gt 0 ]] && ui_kv "Patches" "$(names "${PATCHES[@]}")"
[[ ${#HOTFIXES[@]} -gt 0 ]] && ui_kv "Efixes" "$(names "${HOTFIXES[@]}")"
[[ ${#PLUGINS[@]} -gt 0 ]] && ui_kv "Plugins" "$(names "${PLUGINS[@]}")"
[[ ${#TRUSTEDCERTS[@]} -gt 0 ]] && ui_kv "Certs" "$(names "${TRUSTEDCERTS[@]}")"
[[ ${#OBJECTS[@]} -gt 0 ]] && ui_kv "Objects" "$(names "${OBJECTS[@]}")"
[[ ! -z "${LABEL}" ]] && ui_kv "Label" "${LABEL}"

ui_section "Preparing"
HERE=`pwd`
mkdir -p "${HERE}/build/tmp"
BUILD="${HERE}/build"

# Clear out anything left from a previous build (extracted zip contents, WEB-INF, build.log, etc.)
# Only clear it if it is really the 'build' folder next to this script (not a symlink, not the wrong cwd)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
if [[ -L "${BUILD}" ]] || [[ ! -d "${BUILD}" ]] || [[ "$(cd "${BUILD}" && pwd -P)" != "${SCRIPT_DIR}/build" ]]; then
	ui_die 4 "Refusing to clear ${BUILD}; it is not the 'build' directory next to build.sh (${SCRIPT_DIR}). Run this script from the repository directory."
fi
find "${BUILD}" -mindepth 1 ! -path "${BUILD}/tmp" ! -path "${BUILD}/tmp/*" -delete

# Output of long-running steps goes here
UI_LOG="${BUILD}/build.log"
ui_ok "Build directory cleaned" "build/"

IIQ_VERSION=
IIQ_PATCH=

# Sanity checking for optional SSB build
if [[ ! -z "$SSB" ]]; then
	if [[ ! -z $(echo "${SSB}" | grep "git\\.") ]]; then
		ui_run "Checking out SSB from Git" checkout_ssb || ui_die 1 "Could not check out ${SSB}; see build/build.log"
		SSB="${BUILD}/tmp/ssb"
	fi
	SSB="${SSB%/}"
	if [[ ! -f "${SSB}/build.xml" ]]; then
		ui_die 1 "Option -b directory '${SSB}' does not contain a build.xml"
	fi

	BUILD_PROPERTIES="${SSB}/build.properties"
	if [[ ! -e "${BUILD_PROPERTIES}" ]]; then
		BUILD_PROPERTIES="${SSB}/${SPTARGET}.build.properties"
		if [[ ! -e "${BUILD_PROPERTIES}" ]]; then
			ui_die 1 "No build.properties or ${SPTARGET}.build.properties found"
		fi
	fi

	# This goofy construct is needed to compensate for DOS-formatted files with a \r in them
	IIQ_VERSION=`grep IIQVersion "${BUILD_PROPERTIES}" | head -1 | awk -F "=" '{print $2}' | tr -d '\r'`
	IIQ_PATCHLEVEL=`grep IIQPatchLevel "${BUILD_PROPERTIES}" | awk -F "=" '{print $2}' | tr -d '\r'`

	if [[ ! -z "${IIQ_PATCHLEVEL}" ]]; then
		IIQ_PATCH="$IIQ_VERSION$IIQ_PATCHLEVEL"
		ui_info "Identified IIQ patch $IIQ_PATCH"
	fi

	ANT=`which ant`
	if [[ -z "${ANT}" ]]; then
		ui_die 2 "The 'ant' executable is not available on your path"
	fi

	JAVA=`which java`
	if [[ -z "${JAVA}" ]]; then
		ui_die 3 "The 'java' executable is not available on your path"
	fi
fi

if [[ ! -z "$IIQ_ZIP" ]]; then
	IIQ_ZIP=`realname "${IIQ_ZIP}"`
fi

# Start building
ui_section "Source"
if [[ ! -z "${SSB}" ]]; then
	export SPTARGET
	ui_run "Building SSB" build_ssb
	if [[ ! -e "${SSB}/build/deploy/identityiq.war" ]]; then
		ui_die 9 "The SSB build does not appear to have produced an identityiq.war; please see build/build.log for details"
	fi
	cp "${SSB}/build/deploy/identityiq.war" "${BUILD}" 2> /dev/null
else
	if [[ ! -z "$IIQ_ZIP" ]]; then
		ui_run "Extracting WAR from IIQ zip" extract_zip || ui_die 9 "Failed to extract $IIQ_ZIP"
	else
		cp "${IIQ_WAR}" "${BUILD}/identityiq.war"
		ui_ok "Using IIQ WAR" "$(basename "${IIQ_WAR}")"
	fi
fi

if [[ ! -e "${BUILD}/identityiq.war" ]]; then
	ui_die 9 "The build directory does not contain an identityiq.war"
fi

cp "${BUILD}/identityiq.war" iiq-build/sailpoint/

# Figure out the version from the identityiq.war
pushd "${BUILD}"
unzip -qo "${BUILD}/identityiq.war" WEB-INF/lib/identityiq.jar
if [[ ! -e "${BUILD}/WEB-INF/lib/identityiq.jar" ]]; then
	popd
	ui_die 9 "Failed to extract identityiq.jar"
fi
popd

IIQ_VERSION=$(unzip -p "${BUILD}/WEB-INF/lib/identityiq.jar" META-INF/MANIFEST.MF | grep Implementation-Version | awk -F " " '{print $2}' | tr -d '\r')

if [[ -z "${IIQ_VERSION}" ]]; then
	ui_die 9 "Could not determine the IIQ version from WEB-INF/lib/identityiq.jar in the WAR"
fi

ui_ok "Detected IIQ version ${IIQ_VERSION}"

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

if [[ ${#PATCHES[@]} -gt 0 ]] || [[ ${#HOTFIXES[@]} -gt 0 ]] || [[ ${#PLUGINS[@]} -gt 0 ]] || [[ ${#TRUSTEDCERTS[@]} -gt 0 ]] || [[ ${#OBJECTS[@]} -gt 0 ]]; then
	ui_section "Staging"
fi

for patch in "${PATCHES[@]}"
do
	cp "$patch" "iiq-build/src/patch"
	ui_ok "Patch archive" "$(basename "$patch")"
done

for efix in "${HOTFIXES[@]}"
do
	cp "$efix" "iiq-build/src/efix"
	ui_ok "Efix archive" "$(basename "$efix")"
done

for plugin in "${PLUGINS[@]}"
do
	cp "$plugin" "iiq-build/src/plugins"
	ui_ok "Plugin archive" "$(basename "$plugin")"
done

for cert in "${TRUSTEDCERTS[@]}"
do
	cp "$cert" "iiq-build/src/certs"
	ui_ok "Trusted SSL certificate" "$(basename "$cert")"
done

for object in "${OBJECTS[@]}"
do
	cp -rf "$object" "iiq-build/src/objects"
	ui_ok "Objects" "$(basename "$object")"
done

ui_section "Docker"
IIQ_MAJOR="${IIQ_VERSION%%.*}"
if [[ "${IIQ_MAJOR}" =~ ^[0-9]+$ ]] && (( IIQ_MAJOR >= 9 )); then
	export TOMCAT_VERSION=10-jdk21-temurin-noble
	export JDK_VERSION=21-jdk-noble
	ui_info "Using Tomcat 10 for IIQ 9+"
fi

IMAGE=git.identityworksllc.com:5005/idw/idw-sailpoint/sailpoint-docker
ui_info "This usually takes a minute or two" "full output in build/build.log"
ui_run "Building Docker images" docker compose --progress plain build || ui_die 10 "Docker build failed; see build/build.log for details"

if [[ ! -z "${LABEL}" ]]; then
	docker tag "${IMAGE}:latest" "${IMAGE}:${LABEL}" || ui_die 10 "Failed to tag the image as ${LABEL}"
	ui_ok "Tagged image 'latest' as ${LABEL}"
fi

ui_section "Image"
ui_kv "Name" "${IMAGE}:latest"
if [[ ! -z "${LABEL}" ]]; then
	ui_kv "Tag" "${IMAGE}:${LABEL}"
fi

ui_section "Next steps"
ui_info "Run ${C_BOLD}./start.sh${C_RESET} for a quick startup"

ui_outro "Done in $(ui_elapsed ${SECONDS})"
