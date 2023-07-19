#!/bin/bash

BASE_URL="https://git.identityworksllc.com"
API_URL="${BASE_URL}/api/v4"
IIQ_COMMON_REPO_ID=157

PACKAGE_ID=$(curl -s -m 30 "${API_URL}/projects/${IIQ_COMMON_REPO_ID}/packages?sort=desc" |  jq '.[0].id')

if [[ -z "${PACKAGE_ID}" ]]; then
  echo "Could not find a package in the IIQCommon Public project??"
  exit 1
fi

echo "Package ID is ${PACKAGE_ID}"

FILE_ID=$(curl -s -m 30 "${API_URL}/projects/${IIQ_COMMON_REPO_ID}/packages/${PACKAGE_ID}/package_files" | jq '.[] | select(.file_name|test("iiq-common-public-[0123456789\\.]+jar$")) | .id')
FILE_HASH=$(curl -s -m 30 "${API_URL}/projects/${IIQ_COMMON_REPO_ID}/packages/${PACKAGE_ID}/package_files" | jq '.[] | select(.file_name|test("iiq-common-public-[0123456789\\.]+jar$")) | .file_sha1' | sed 's/"//g')

echo "File ID is ${FILE_ID} and SHA-1 hash is ${FILE_HASH}"

FILE_URL="${BASE_URL}/pub/iiqcommon/-/package_files/${FILE_ID}/download"

# Download the actual file. Note the longer timeout, for slow Internet situations
curl -s -m 240 "${FILE_URL}" > iiq-common-public.jar

DOWNLOADED_HASH=$(shasum iiq-common-public.jar | awk '{print $1}')

if [[ ${FILE_HASH} != ${DOWNLOADED_HASH} ]]; then
  echo "Downloaded file does not match the repository hash"
  rm iiq-common-public.jar
  exit 2
else
  echo "Successfully downloaded iiq-common-public.jar"
fi