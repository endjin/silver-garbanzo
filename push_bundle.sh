#!/bin/bash

set -e 

echo "Installing ORAS"
curl https://github.com/deislabs/oras/releases/download/v0.5.0/oras_0.5.0_linux_amd64.tar.gz -fLo "${agent_temp_directory}/oras_0.5.0_linux_amd64.tar.gz"
oras_install="${agent_temp_directory}/oras"
mkdir -p  "${oras_install}"
tar -zxf "${agent_temp_directory}/oras_0.5.0_linux_amd64.tar.gz" -C "${oras_install}"
chmod +x "${oras_install}/oras"
echo "Installed ORAS"

oras_name="${image_registry}/${image_repo}/bundle.json:latest"
echo "Pushing bundle.json to registry using ORAS: ${oras_name}"
oras push "${oras_name}" bundle.json
echo "Pushed bundle.json to registry using ORAS: ${oras_name}"