#!/bin/bash
set -e 

build_required=false

function check_required_files() {
   
    echo "Validating Files"

    # TODO Validate the files
    # Need to support file existing in the target repo

    # if [ ! -f  ${repo_local_path}/${tool}/azuredeploy.json ]; then   
    #     echo "Solution should contain an ARM template to deploy the solution named azuredeploy.json."
    #     exit 1
    # fi

    # if [ ! -f  ${repo_local_path}/${tool}/azuredeploy.json ]; then 
    #     echo "Solution should contain an metadata file named metadata.json."
    #     exit 1
    # fi

}

# Update could be in either the duffle or the porter directory or it could be an update that is not related to a solution, this should only happen on a merge as builds are only trigged for PR when changes are made in the dufffle or porter folder

echo "Get the files in the PR or merge commit to find the solution folder name"

# TODO ignore files that start with .

if [ "${reason}" == "push" ]; then
    owner_and_repo="${repo_uri##https://github.com/}"
    commit_uri=https://api.github.com/repos/${owner_and_repo}/commits/${source_version}
    echo "Merge Commit uri: ${commit_uri}"
    files=$(curl "${commit_uri}"|jq '[.files[].filename]') 
fi

if [ "${reason}" == "pull_request" ]; then
    pr_uri="https://api.github.com/repos/${repo_name}/pulls/${pr_number}/files"
    echo "PR uri: ${pr_uri}"
    files=$(curl "${pr_uri}"|jq '[.[].filename]') 
fi

printf "file:\\n%s\\n" "${files}"

# TODO: Need to handle multiple solution changes
# TODO: Need to handle changes to build nd client folders

tool=$(echo "${files}"|jq 'if . | contains(["/"]) then .|map(select(contains("/")))[0]|split("/")[0]  else empty end' --raw-output)

echo ::set-env name=tool::${tool}
printf "tool:%s\\n" "${tool}"


# Each bundle definition should exist with a directory under the duffle directory - the folder name is derived from the set of files that have been changed in this pull request

if [[ ! -z "${tool}" && ("${tool}" == "duffle" || "${tool}" == "porter") ]]; then
    if [ "$(find "${GITHUB_WORKSPACE}/${tool}" -maxdepth 1 ! -type d ! -name '.*' ! -name README.md)" ]; then 
        printf "Files should not be placed in the %s directory - only %s solution folders in this folder. \\n" "${tool}" "${tool}"
        exit 1 
    fi
    folder=$(echo "${files}"|jq --arg tool "${tool}" '.|map(select(startswith($tool)))[0]|split("/")[1]' --raw-output)
    echo ::set-env name=tool::${tool}
fi

printf "folder:%s\\n" "${folder}"

# Porter Solution

if [ "${tool}" == "porter" ]; then

    check_required_files

    porter_home="${GITHUB_WORKSPACE}/porter"

    # TODO revert release once permission fix is available
    # porter_url=https://cdn.deislabs.io/porter
    # porter_version="${porter_version:-latest}"
    # feed_url="${porter_url}/atom.xml"
    
    porter_url=https://github.com/simongdavies/porter/releases/download/
    porter_version="fix"
    feed_url="https://cdn.deislabs.io/porter/atom.xml"
    
    echo "Installing porter to ${porter_home}"
    mkdir -p "${porter_home}"
    curl -fLo "${porter_home}/porter" "${porter_url}/${porter_version}/porter-linux-amd64"
    chmod +x "${porter_home}/porter"
    cp "${porter_home}/porter" "${porter_home}/porter-runtime"
    echo Installed "$("${porter_home}/porter" version)"

    # TODO revert release once permission fix is available
    porter_version="latest"

    echo "Installing mixins"
    "${porter_home}/porter" mixin install exec --version "${porter_version}" --feed-url "${feed_url}"
    "${porter_home}/porter" mixin install kubernetes --version "${porter_version}" --feed-url "${feed_url}"
    "${porter_home}/porter" mixin install helm --version "${porter_version}" --feed-url "${feed_url}"
    "${porter_home}/porter" mixin install azure --version "${porter_version}" --feed-url "${feed_url}"
    echo "Installed mixins"

    # Export environment variables

    taskdir=${GITHUB_WORKSPACE}/porter/${folder}

    echo ::set-env name=porter_home::${porter_home}
    echo ::set-env name=taskdir::${taskdir}

    cd ${taskdir}

    # install yq to parse the porter.yaml file
     
    echo "Installing yq"
    python -m pip install --upgrade pip yq
    echo "Installed yq"

    cnab_name=$(yq .name porter.yaml -r)
    echo "CNAB Name:${cnab_name}"

    if [ "${cnab_name}" != "${folder}" ]; then 
        printf "Name property should in porter.yaml should be the same as the solution directory name. Name property:%s Directory Name: %s\\n" "${cnab_name}" "${folder}"
        exit 1 
    fi

    invocation_image=$(yq .invocationImage porter.yaml -r)
    echo "invocation_image: ${invocation_image}"

    registry="${invocation_image%/*}"
    echo "registry: ${registry}"

    if [ "${registry}" != "${cnab_quickstart_registry}/${tool}" ]; then 
        printf "Registry/repository portion of invocationImage property should be set to %s in porter.yaml\\n" "${cnab_quickstart_registry}/${tool}"
        exit 1 
    fi

    ii_name="${invocation_image##*/}"
    echo "ii_name: ${ii_name}"

    if [ "${ii_name}" != "${cnab_name}" ]; then 
        printf "Name portion of invocationImage property should be set to %s in porter.yaml\\n" "${cnab_name}"
        exit 1 
    fi

     # set tag to PR Number if this is a PR as porter will update the image in the registry
     # TODO remove this when option is provided to prevent push

    if [ "${reason}" == "PullRequest" ]; then
        tmpfile=$(mktemp)
        yq -y --arg image "${registry}/${cnab_name}:pr${pr_number}" '.invocationImage = $image' > "${tmpfile}" < porter.yaml
        mv "${tmpfile}" porter.yaml
    fi
    image_repo="${cnab_name}" 
    echo "image_repo: ${image_repo}"
    
    echo ::set-env name=image_repo::${image_repo}
    echo ::set-env name=image_registry::${cnab_quickstart_registry}/${tool}

    build_required=true
fi

echo ::set-env name=BuildRequired::${build_required}
