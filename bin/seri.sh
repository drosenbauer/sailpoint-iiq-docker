#!/bin/bash
# Installs a SERI use case or plugin from config/seri/catalog: bin/seri.sh UseCase-XYZ

cd "$(dirname "$0")/.." || exit 1
source bin/include/utils.sh

# Git Bash: don't rewrite the Linux paths below into Windows paths
export MSYS_NO_PATHCONV=1

console() {
	command=$1
	greenecho "Invoking console command $command"
	# -T: no terminal needed, since input is piped in and output is filtered
	docker compose exec -T iiq /bin/bash -c "echo '$command' | /opt/tomcat/webapps/identityiq/WEB-INF/bin/iiq console" | grep -v "deprecated" | grep -v "MySQL" | grep -v "sailpoint.persistence.ExtendedAttributeUtil"
}

SERI_ITEM=$1

if [[ -z "${SERI_ITEM}" ]]; then
	redecho "Usage: bin/seri.sh <catalog folder name>"
	exit 1
fi

if [[ "${SERI_ITEM}" != *Plugin* ]]; then
	# XML import
	greenecho "Installing SERI utility or use-case $SERI_ITEM"
	console "import seri/catalog/${SERI_ITEM}/setup.xml"
else
	# Plugin
	greenecho "Installing plugins $SERI_ITEM"
	console "plugin install /opt/tomcat/webapps/identityiq/WEB-INF/config/seri/catalog/${SERI_ITEM}"
fi
