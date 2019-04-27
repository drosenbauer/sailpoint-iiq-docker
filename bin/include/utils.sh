realname() {
        echo "$(cd "$(dirname "$1")"; pwd)/$(basename "$1")"
}

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

