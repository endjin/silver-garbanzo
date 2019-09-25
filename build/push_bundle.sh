#!/bin/bash

cd ${taskdir}

set -e 

echo "Installing ORAS"
curl https://github.com/deislabs/oras/releases/download/v0.5.0/oras_0.5.0_linux_amd64.tar.gz -fLo "${GITHUB_WORKSPACE}/oras_0.5.0_linux_amd64.tar.gz"
oras_install="${GITHUB_WORKSPACE}/oras"
mkdir -p  "${oras_install}"
tar -zxf "${GITHUB_WORKSPACE}/oras_0.5.0_linux_amd64.tar.gz" -C "${oras_install}"
chmod +x "${oras_install}/oras"
echo "Installed ORAS"

oras_name="${image_registry}/${image_repo}/bundle.json:latest"
echo "Pushing bundle.json to registry using ORAS: ${oras_name}"
"${oras_install}/oras" push "${oras_name}" bundle.json
echo "Pushed bundle.json to registry using ORAS: ${oras_name}"