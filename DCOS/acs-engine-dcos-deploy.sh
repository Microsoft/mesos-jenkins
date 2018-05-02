#!/usr/bin/env bash
set -e

CI_WEB_ROOT="http://dcos-win.westus.cloudapp.azure.com"


validate_simple_deployment_params() {
    if [[ -z $AZURE_SERVICE_PRINCIPAL_ID ]]; then echo "ERROR: Parameter AZURE_SERVICE_PRINCIPAL_ID is not set"; exit 1; fi
    if [[ -z $AZURE_SERVICE_PRINCIPAL_PASSWORD ]]; then echo "ERROR: Parameter AZURE_SERVICE_PRINCIPAL_PASSWORD is not set"; exit 1; fi
    if [[ -z $AZURE_SERVICE_PRINCIPAL_TENAT ]]; then echo "ERROR: Parameter AZURE_SERVICE_PRINCIPAL_TENAT is not set"; exit 1; fi
    if [[ -z $AZURE_REGION ]]; then echo "ERROR: Parameter AZURE_REGION is not set"; exit 1; fi
    if [[ -z $AZURE_RESOURCE_GROUP ]]; then echo "ERROR: Parameter AZURE_RESOURCE_GROUP is not set"; exit 1; fi

    if [[ -z $LINUX_MASTER_SIZE ]]; then echo "ERROR: Parameter LINUX_MASTER_SIZE is not set"; exit 1; fi
    if [[ -z $LINUX_MASTER_DNS_PREFIX ]]; then echo "ERROR: Parameter LINUX_MASTER_DNS_PREFIX is not set"; exit 1; fi
    if [[ -z $LINUX_ADMIN ]]; then echo "ERROR: Parameter LINUX_ADMIN is not set"; exit 1; fi
    if [[ -z $LINUX_PUBLIC_SSH_KEY ]]; then echo "ERROR: Parameter LINUX_PUBLIC_SSH_KEY is not set"; exit 1; fi

    if [[ -z $WIN_AGENT_SIZE ]]; then echo "ERROR: Parameter WIN_AGENT_SIZE is not set"; exit 1; fi
    if [[ -z $WIN_AGENT_PUBLIC_POOL ]]; then echo "ERROR: Parameter WIN_AGENT_PUBLIC_POOL is not set"; exit 1; fi
    if [[ -z $WIN_AGENT_DNS_PREFIX ]]; then echo "ERROR: Parameter WIN_AGENT_DNS_PREFIX is not set"; exit 1; fi
    if [[ -z $WIN_AGENT_ADMIN ]]; then echo "ERROR: Parameter WIN_AGENT_ADMIN is not set"; exit 1; fi
    if [[ -z $WIN_AGENT_ADMIN_PASSWORD ]]; then echo "ERROR: Parameter WIN_AGENT_ADMIN_PASSWORD is not set"; exit 1; fi

    if [[ ! -z $DCOS_VERSION ]] && [[ "$DCOS_VERSION" != "1.8.8" ]] && [[ "$DCOS_VERSION" != "1.9.0" ]] && [[ "$DCOS_VERSION" != "1.10.0" ]] && [[ "$DCOS_VERSION" != "1.11.0" ]]; then
        echo "ERROR: Supported DCOS_VERSION are: 1.8.8, 1.9.0, 1.10.0 or 1.11.0"
        exit 1
    fi
    if [[ -z $DCOS_WINDOWS_BOOTSTRAP_URL ]]; then
        export DCOS_WINDOWS_BOOTSTRAP_URL="$CI_WEB_ROOT/dcos-windows/testing"
    fi
    if [[ -z $DCOS_BOOTSTRAP_URL ]]; then
        export DCOS_BOOTSTRAP_URL="$CI_WEB_ROOT/dcos/bootstrap/latest.bootstrap.tar.xz"
    fi
    if [[ -z $DCOS_REPOSITORY_URL ]]; then
        export DCOS_REPOSITORY_URL="$CI_WEB_ROOT/dcos"
    fi
    if [[ -z $DCOS_CLUSTER_PACKAGE_LIST_ID ]]; then
        export DCOS_CLUSTER_PACKAGE_LIST_ID=$(curl -L $CI_WEB_ROOT/dcos/cluster-package-list.latest)
    fi
}

validate_extra_hybrid_deployment_params() {
    if [[ -z $LINUX_AGENT_SIZE ]]; then echo "ERROR: Parameter LINUX_AGENT_SIZE is not set"; exit 1; fi
    if [[ -z $LINUX_AGENT_PUBLIC_POOL ]]; then echo "ERROR: Parameter LINUX_AGENT_PUBLIC_POOL is not set"; exit 1; fi
    if [[ -z $LINUX_AGENT_DNS_PREFIX ]]; then echo "ERROR: Parameter LINUX_AGENT_DNS_PREFIX is not set"; exit 1; fi
    if [[ -z $LINUX_AGENT_PRIVATE_POOL ]]; then echo "ERROR: Parameter LINUX_AGENT_PRIVATE_POOL is not set"; exit 1; fi

    if [[ -z $WIN_AGENT_PRIVATE_POOL ]]; then echo "ERROR: Parameter WIN_AGENT_PRIVATE_POOL is not set"; exit 1; fi
}

install_go_1_8() {
    which go > /dev/null && echo "Go is already installed" && return || echo "Installing Go 1.8"
    OUT_FILE="/tmp/go-1.8.tgz"
    GO_1_8_TGZ_URL="https://storage.googleapis.com/golang/go1.8.linux-amd64.tar.gz"
    wget $GO_1_8_TGZ_URL -O $OUT_FILE
    pushd $(dirname $OUT_FILE)
    tar xzf $OUT_FILE
    sudo mv go /usr/local
    popd
    rm -rf $OUT_FILE
    cat ~/.bashrc | grep -q '^export GOPATH=~/golang$' || (echo 'export GOPATH=~/golang' >> ~/.bashrc)
    cat ~/.bashrc | grep -q '^export PATH="\$PATH:/usr/local/go/bin:\$GOPATH/bin"$' || (echo 'export PATH="$PATH:/usr/local/go/bin:$GOPATH/bin"' >> ~/.bashrc)
    source ~/.bashrc
    mkdir -p $GOPATH
}

install_acs_engine_requirements() {
    which git > /dev/null && echo "Git is already installed" || sudo apt install git -y
    install_go_1_8
}

install_acs_engine_from_src() {
    which acs-engine > /dev/null && echo "ACS Engine is already installed" && return || echo "Installing ACS Engine from source"
    install_acs_engine_requirements
    go get -v github.com/Azure/acs-engine
    pushd $GOPATH/src/github.com/Azure/acs-engine
    make bootstrap
    make build
    if [[ ! -e ~/bin ]]; then
        mkdir -p ~/bin
        PATH="$HOME/bin:$PATH"
    fi
    cp $GOPATH/src/github.com/Azure/acs-engine/bin/acs-engine ~/bin/
    popd
}

install_azure_cli_2() {
    which az > /dev/null && echo "Azure CLI is already installed" && return || echo "Installing Azure CLI"
    echo "deb [arch=amd64] https://packages.microsoft.com/repos/azure-cli/ wheezy main" | sudo tee /etc/apt/sources.list.d/azure-cli.list
    sudo apt-key adv --keyserver packages.microsoft.com --recv-keys 417A0893
    sudo apt-get install apt-transport-https
    sudo apt-get update && sudo apt-get install azure-cli
}

azure_cli_login() {
    if az account list --output json | jq -r '.[0]["user"]["name"]' | grep -q "^${AZURE_SERVICE_PRINCIPAL_ID}$"; then
        echo "Account is already logged"
        return
    fi
    az login --output table --service-principal -u $AZURE_SERVICE_PRINCIPAL_ID -p $AZURE_SERVICE_PRINCIPAL_PASSWORD --tenant $AZURE_SERVICE_PRINCIPAL_TENAT
}

# Check if all parameters are set
if [[ -z $DCOS_DEPLOYMENT_TYPE ]]; then echo "ERROR: Parameter DCOS_DEPLOYMENT_TYPE is not set"; exit 1; fi
validate_simple_deployment_params
if [[ "$DCOS_DEPLOYMENT_TYPE" = "hybrid" ]]; then
    validate_extra_hybrid_deployment_params
fi

BASE_DIR=$(dirname $0)
TEMPLATES_DIR="$BASE_DIR/templates"

# Install ACS Engine from the 'dcos-windows' branch and Azure CLI 2.0
install_acs_engine_from_src
install_azure_cli_2

# Generate the Azure ARM deploy files
if [[ ! -z $DCOS_VERSION ]]; then
    ACS_TEMPLATE="$TEMPLATES_DIR/acs-engine/stable/${DCOS_DEPLOYMENT_TYPE}.json"
else
    ACS_TEMPLATE="$TEMPLATES_DIR/acs-engine/testing/${DCOS_DEPLOYMENT_TYPE}.json"
fi
if [[ -z $DCOS_DEPLOY_DIR ]]; then
    DCOS_DEPLOY_DIR=$(mktemp -d -t "dcos-deploy-XXXXXXXXXX")
else
    mkdir -p $DCOS_DEPLOY_DIR
fi
ACS_RENDERED_TEMPLATE="${DCOS_DEPLOY_DIR}/acs-engine-template.json"
eval "cat << EOF
$(cat $ACS_TEMPLATE)
EOF
" > $ACS_RENDERED_TEMPLATE
acs-engine generate --output-directory $DCOS_DEPLOY_DIR $ACS_RENDERED_TEMPLATE
rm -rf ./translations # Left-over after running 'acs-engine generate'

# Deploy the DC/OS with Mesos environment
DEPLOY_TEMPLATE_FILE="$DCOS_DEPLOY_DIR/azuredeploy.json"
DEPLOY_PARAMS_FILE="$DCOS_DEPLOY_DIR/azuredeploy.parameters.json"

azure_cli_login
EXTRA_PARAMS=""
if [[ "$DEBUG" = "true" ]]; then
    EXTRA_PARAMS="$EXTRA_PARAMS --debug"
fi
if [[ "$VERBOSE" = "true" ]]; then
    EXTRA_PARAMS="$EXTRA_PARAMS --verbose"
fi
CLEANUP_TAG=""
if [[ "$SET_CLEANUP_TAG" = "true" ]]; then
    CLEANUP_TAG="--tags now=$(date +%s)"
fi
az group create -l "$AZURE_REGION" -n "$AZURE_RESOURCE_GROUP" -o table $TAGS $EXTRA_PARAMS $CLEANUP_TAG
echo "Validating the DC/OS ARM deployment templates"
az group deployment validate -g "$AZURE_RESOURCE_GROUP" --template-file $DEPLOY_TEMPLATE_FILE --parameters @$DEPLOY_PARAMS_FILE -o table $EXTRA_PARAMS
echo "Started the DC/OS deployment"
az group deployment create -g "$AZURE_RESOURCE_GROUP" --template-file $DEPLOY_TEMPLATE_FILE --parameters @$DEPLOY_PARAMS_FILE -o table $EXTRA_PARAMS
rm -rf $DCOS_DEPLOY_DIR
