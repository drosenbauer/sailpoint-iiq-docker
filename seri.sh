#!/bin/bash


pushd () {
    command pushd "$@" > /dev/null
}

popd () {
    command popd "$@" > /dev/null
}

greenecho() {
        text=$1
        echo -e "\033[1;32m${text}\033[0m"
}

redecho() {
        text=$1
        echo -e "\033[1;31m${text}\033[0m"
}

console() {
	command=$1
	greenecho "Invoking console command $command"
	docker-compose -p iiq exec "iiq-master" /bin/bash -c "echo '$command' | /opt/tomcat/webapps/identityiq/WEB-INF/bin/iiq console" | grep -v "deprecated" | grep -v "MySQL" | grep -v "sailpoint.persistence.ExtendedAttributeUtil"
}

SERI_ITEM=$1

if [[ -z `echo $SERI_ITEM | grep Plugin` ]]; then
	# XML import
	greenecho "Installing SERI utility or use-case $SERI_ITEM"
	console "import seri/catalog/${SERI_ITEM}/setup.xml"
else
	# Plugin
	greenecho "Installing plugins $SERI_ITEM"
	console "plugin install /opt/tomcat/webapps/identityiq/WEB-INF/config/seri/catalog/${SERI_ITEM}"
fi
