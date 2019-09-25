#!/bin/bash
set -e
CNAB_QUICKSTART_REGISTRY="endjincnabdev01.azurecr.io"
DEFAULT_CNAB_STATE_SHARE_NAME=cnabstate

# Script to run duffle using ACI Driver in Docker
# All arguments are expected to be in ENV VARS
# Requires the following arguments plus any parameters/creds for the bundle 

parameterisrequired() {
    [[ (! $(cat bundle.json|jq --arg key "${param}" '.parameters|.[$key]|has("defaultValue")') == true ) || (($(cat bundle.json|jq --arg key "${param}" '.parameters|.[$key]|has("required")') == true)  ) && ($(cat bundle.json|jq -r --arg key "${param}" '.parameters[$key].required'|awk '{ print tolower($0) }') == "true") ]]
    return
}

# CNAB_INSTALLATION_NAME
# CNAB_ACTION
# CNAB_BUNDLE_NAME The anme os the bundle to install should be in the form of tool/bundlename (e.g porter/{name} or duffle/{name})
# ACI_LOCATION: The location to be used by the Duffle ACI Driver
# CNAB_STATE_STORAGE_ACCOUNT_NAME The storage account name to be used to create an Azure File Share to store CNAB state
# CNAB_STATE_STORAGE_ACCOUNT_KEY The storage account key to be used to create an Azure File Share to store CNAB state if this is not present then the script will try and retrieve it
# CNAB_STATE_SHARE_NAME The file share name to be used for CNAB state storage, if this is empty the DEFAULT_CNAB_STATE_SHARE_NAME
# VERBOSE Enables Verbose output from the duffle ACI Driver

if [ -z "${CNAB_INSTALLATION_NAME}" ]; then 
    echo "Environment Variable CNAB_INSTALLATION_NAME} should be set to the name of the instance installed/updated/deleted" 
    exit 1
fi 

if [ -z "${CNAB_ACTION}" ]; then 
    echo "Environment Variable CNAB_ACTION should be set to the name of action to be taken on the instance" 
    exit 1
fi 

if [ -z "${CNAB_BUNDLE_NAME}" ]; then 
    echo "Environment Variable CNAB_BUNDLE_NAME should be set to the name of the bundle to be installed/updated/deleted" 
    exit 1
fi 

if [ -z "${ACI_LOCATION}" ]; then 
    echo "Environment Variable ACI_LOCATION should be set to the location to be used by the ACI Driver" 
    exit 1
fi 

# TODO need to support MSI 
# ACR tries to authenticate with MSi even with a public image - needs fix before user MSI ca be used
# use the Client Id and Secret until fix is done

# if [ -z "${ACI_MSI_TYPE}" ]; then 
#     echo "Environment Variable ACI_MSI_TYPE should be set to the MSI type to be used to run ACI" 
#     exit 1
# fi 

# if [ "${ACI_MSI_TYPE}" == "user" ]; then

#     if [ -z "${ACI_USER_MSI_RESOURCE_ID}" ]; then 
#         echo "Environment Variable ACI_USER_MSI_RESOURCE_ID should be should be set to the MSI USer Resource ID to be used to run ACI" 
#         exit 1
#     fi 
#     echo "Logging in with ${ACI_USER_MSI_RESOURCE_ID}"
#     az login --identity -u "${ACI_USER_MSI_RESOURCE_ID}"
# else

#     echo "ACI_MSI_TYPE of ${ACI_MSI_TYPE} is not supported" 
#     exit 1

#     if [ -z "${ACI_SYSTEM_MSI_ROLE}" ]; then 
#         echo "Environment Variable ACI_SYSTEM_MSI_ROLE should be set to the Role to assign to the System MSI used to run ACI" 
#         exit 1
#     fi 

#     if [ -z "${ACI_SYSTEM_MSI_SCOPE}" ]; then 
#         echo "Environment Variable ACI_SYSTEM_MSI_SCOPE should be set to the Scope to assign the ACI_SYSTEM_MSI_ROLE at for the System MSI used to run ACI" 
#         exit 1
#     fi 

# fi

az login --service-principal -u "${AZURE_CLIENT_ID}" -p "${AZURE_CLIENT_SECRET}" --tenant "${AZURE_TENANT_ID}"

if [ -z "${CNAB_STATE_STORAGE_ACCOUNT_NAME}" ]; then 
    echo "Environment Variable CNAB_STATE_STORAGE_ACCOUNT_NAME should be set to the name of the storage account used for the state file share" 
    exit 1
else 
    if [[ ! $(az storage account show -n "${CNAB_STATE_STORAGE_ACCOUNT_NAME}" ) ]]; then  
        echo "CNAB_STATE_STORAGE_ACCOUNT_NAME Storage Account ${CNAB_STATE_STORAGE_ACCOUNT_NAME}  was not found" 
        exit 1
    fi
fi 

if [ -z "${CNAB_STATE_STORAGE_ACCOUNT_KEY}" ]; then 
    CNAB_STATE_STORAGE_ACCOUNT_KEY=$(az storage account keys list -n ${CNAB_STATE_STORAGE_ACCOUNT_NAME} --query '[]|[0].value' -o tsv)
    if [ -z "${CNAB_STATE_STORAGE_ACCOUNT_KEY}" ]; then 
        echo "Cannot get Storage Account Key for storage account ${CNAB_STATE_STORAGE_ACCOUNT_NAME}"
    fi 
fi 

if [ -z "${CNAB_STATE_SHARE_NAME}" ]; then 
    CNAB_STATE_SHARE_NAME="${DEFAULT_CNAB_STATE_SHARE_NAME}"
    # TODO Validate share name
fi 

if [[ ! ${VERBOSE} = "true" ]]; then 
    VERBOSE=false
fi

oras pull "${CNAB_QUICKSTART_REGISTRY}/${CNAB_BUNDLE_NAME}/bundle.json:latest"

# Look for parameters in the bundle.json and set them in a TOML File
# Expects to find parameter values in ENV variable named after the bundle parameter in UPPER case
# Ignores missing environment variables if the parameter has a default value

# TODO Support File Source as well as ENV

touch params.toml

parameters=$(cat bundle.json|jq '.parameters|keys|.[]' -r)


for param in ${parameters};do 
    
    # Its expcted that each parameters value is passed in using a correspondingly named variable, in some cases the bundle parameter name will not be a valid environment variable name
    # e.g. in cases where the parameter names are not defined in the bundle but are injected by the tool (e.g porter-debug)
    # These will get ignored if there are defaults 
    
    var=$(echo "${param^^}")

    if [[ ! $param =~ ^[a-zA-Z_]+[a-zA-Z0-9_]*$ ]]; then 
        if parameterisrequired; then
            printf "Bundle expects parameter: %s to be set but parameter name translates to illegal env var name: %s\\n" "${param}" "${var}"
            exit 1
        fi
        printf "Parameter %s has illegal ENV variable translation ignoring\\n" "${param}"
        continue
    fi
    
    if [ -z ${!var:-''} ]; then
        # Only require a value if parameter is required
         if parameterisrequired; then 
            printf "Bundle expects parameter: %s to be set using environment variable: %s\\n" "${param}" "${var}"
            exit 1
        fi
    else
        echo "${param}=\"${!var}\"" >> params.toml
    fi

done

# Look credentials in the bundle.json and set them in a credentials file
# Expects to find credentials values in ENV variable named after the bundle credential in UPPER case

touch credentials.yaml

echo "name: credentials" >> credentials.yaml
echo "credentials:" >> credentials.yaml

credentials=$(cat bundle.json|jq '.credentials|keys|.[]' -r)

for cred in ${credentials}; do
    var=$(echo "${cred^^}")
    if [ -z ${!var:-} ]; then
        printf "Bundle expects credential: %s to be set using environment variable: %s\\n" "${cred}" "${var}"
        exit 1
    else
        printf "%s name: %s \\n  source: \\n   env: %s \\n" "-" "${cred}" "${var}" >> credentials.yaml
    fi
done

# DUFFLE_HOME="${CNAB_STATE_MOUNT_POINT}/${CNAB_BUNDLE_NAME}/${CNAB_INSTALLATION_NAME}"

DUFFLE_HOME="${HOME}/.duffle"

# we have to copy files to and from file share as there is no way to create a file share in an ARM template and we cannot mount a cifs file share inside ACI as there are not enough permissions

# Check if the fileshare exists and if not create it

if [[ ! $(az storage share show --name "${CNAB_STATE_SHARE_NAME}" --account-name "${CNAB_STATE_STORAGE_ACCOUNT_NAME}" --account-key "${CNAB_STATE_STORAGE_ACCOUNT_KEY}" ) ]];then  
    printf "File Share %s not found in storage account %s Creating...\\n" ${CNAB_STATE_SHARE_NAME} ${CNAB_STATE_STORAGE_ACCOUNT_NAME}
    if [[ ! $(az storage share create --name "${CNAB_STATE_SHARE_NAME}" --account-name "${CNAB_STATE_STORAGE_ACCOUNT_NAME}" --account-key "${CNAB_STATE_STORAGE_ACCOUNT_KEY}") ]];then  
        echo "Failed to create CNAB_STATE_SHARE_NAME ${CNAB_STATE_SHARE_NAME} on CNAB_STATE_STORAGE_ACCOUNT_NAME ${CNAB_STATE_STORAGE_ACCOUNT_NAME}"
        exit 1
    else
         printf "File Share %s in storage account %s Created.\\n" ${CNAB_STATE_SHARE_NAME} ${CNAB_STATE_STORAGE_ACCOUNT_NAME}
    fi
fi

# Copy my existing files in the share to local disk

echo "generating SAS token"

EXPIRY=$(date -d '30 minute' '+%Y-%m-%dT%H:%MZ')
SAS_TOKEN=$(az storage share generate-sas -n "${CNAB_STATE_SHARE_NAME}" --account-name "${CNAB_STATE_STORAGE_ACCOUNT_NAME}" --https-only --permissions dlrw --expiry "${EXPIRY}" -o tsv)
 
echo "copying files from state share"                     

duffle init

if [[ ! $(az storage file list --share-name $CNAB_STATE_SHARE_NAME  --account-name $CNAB_STATE_STORAGE_ACCOUNT_NAME --query '[]|length(@)') == 0 ]]; then

    azcopy copy "https://${CNAB_STATE_STORAGE_ACCOUNT_NAME}.file.core.windows.net/${CNAB_STATE_SHARE_NAME}/*?${SAS_TOKEN}" "${DUFFLE_HOME}" --recursive --overwrite

fi

# mv credentials.yaml "${DUFFLE_HOME}/credentials/credentials.yaml"

# TODO Support custom actions

case "${CNAB_ACTION}" in
    install)
        echo "Installing the Application"  
        duffle install "${CNAB_INSTALLATION_NAME}" bundle.json -f -d aci-driver -c ./credentials.yaml -p params.toml -v 
        ;;
    uninstall)
        echo "Destroying the Application"        
        duffle uninstall "${CNAB_INSTALLATION_NAME}" -d aci-driver -c ./credentials.yaml -p params.toml -v
        ;;
    upgrade)
        echo "Upgrading the Application"
        duffle upgrade "${CNAB_INSTALLATION_NAME}" -d aci-driver -c ./credentials.yaml -p params.toml -v
        ;;
    *)
        echo "No action for ${CNAB_ACTION}"
        ;;
esac

echo "generating SAS token"

EXPIRY=$(date -d '30 minute' '+%Y-%m-%dT%H:%MZ')
SAS_TOKEN=$(az storage share generate-sas -n "${CNAB_STATE_SHARE_NAME}" --account-name "${CNAB_STATE_STORAGE_ACCOUNT_NAME}" --https-only --permissions dlrw --expiry "${EXPIRY}" -o tsv)
 
echo "copying files to state share"                     

azcopy copy "${DUFFLE_HOME}/*" "https://${CNAB_STATE_STORAGE_ACCOUNT_NAME}.file.core.windows.net/${CNAB_STATE_SHARE_NAME}?${SAS_TOKEN}" --recursive --overwrite

echo "Complete"