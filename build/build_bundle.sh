#!/bin/bash

cd ${taskdir}

set -e 

echo "Building Bundle in Solution Directory: $(pwd) using ${tool}"

#TODO add testing support

if [ "${tool}" == "duffle" ]; then
    duffle init
    duffle build -o bundle.json
fi

if [ "${tool}" == "porter" ]; then
    porter build
fi

printf "Filter:%s\\n" "${image_registry}/${image_repo}"
ii_tag="$(docker image ls ${image_registry}/${image_repo} --format='{{lower .Tag}}')"
echo "Invocation Image Tag: ${ii_tag}"
echo ::set-env name=ii_tag::${ii_tag}
