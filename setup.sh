#!/bin/sh
set -e

gum style \
	--foreground 212 --border-foreground 212 --border double \
	--margin "1 2" --padding "2 4" \
	'Setup for the TODO: video.'

gum confirm '
Are you ready to start?
Feel free to say "No" and inspect the script if you prefer setting up resources manually.
' || exit 0

rm -f .env

################
# Requirements #
################

echo "
## You will need following tools installed:
|Name            |Required             |More info                                          |
|----------------|---------------------|---------------------------------------------------|
|Charm Gum       |Yes                  |'https://github.com/charmbracelet/gum#installation'|
|gitHub CLi      |Yes                  |'https://youtu.be/BII6ZY2Rnlc'                     |
|jq              |Yes                  |'https://stedolan.github.io/jq/download'           |
|yq              |Yes                  |'https://github.com/mikefarah/yq#install'          |
|Google Cloud CLI|If using Google Cloud|'https://cloud.google.com/sdk/docs/install'        |
|AWS CLI         |If using AWS         |'https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html'|
|eksctl          |If using AWS         |'https://eksctl.io/introduction/#installation'     |
" | gum format

gum confirm "
Do you have those tools installed?
" || exit 0

################
# Hyperscalers #
################

echo "
Which Hyperscaler do you want to use?"

HYPERSCALER=$(gum choose "google" "aws" "azure")

echo HYPERSCALER=$HYPERSCALER >> .env

if [[ "$HYPERSCALER" == "azure" ]]; then
    gum style \
        --foreground 212 --border-foreground 212 --border double \
        --margin "1 2" --padding "2 4" \
        'Unfortunately, the demo currently does NOT work in Azure.' \
        '
Please let me know in the comments of the video if you would like
me to add the commands for Azure.' \
        '
I will do my best to add the commands if there is interest or you
can create a pull request if you would like to contribute.'

    exit 0
fi

###############
# GitHub Repo #
###############

echo
echo

GITHUB_ORG=$(gum input --placeholder "GitHub organization (do NOT use GitHub username)")
echo GITHUB_ORG=$GITHUB_ORG >> .env

GITHUB_USER=$(gum input --placeholder "GitHub username")

gh repo fork vfarcic/idp-demo --clone --remote --org ${GITHUB_ORG}

cd idp-demo

gh repo set-default ${GITHUB_ORG}/idp-demo

cd ..

gum confirm "
We need to authorize gc CLI to manage your secrets.
Choose \"No\" if you already authorized it previously.
" && gh auth refresh --hostname github.com --scopes admin:org

gum confirm "
We need to create GitHub secret ORG_ADMIN_TOKEN.
Choose \"No\" if you already have it.
" \
    && ORG_ADMIN_TOKEN=$(gum input --placeholder "Please enter GitHub organization admin token." --password) \
    && gh secret set ORG_ADMIN_TOKEN --body "$ORG_ADMIN_TOKEN" --org ${GITHUB_ORG}

gum confirm "
We need to create GitHub secret DOCKERHUB_USER.
Choose \"No\" if you already have it.
" \
    && DOCKERHUB_USER=$(gum input --placeholder "Please enter Docker user" --password) \
    && gh secret set DOCKERHUB_USER --body "$DOCKERHUB_USER" --org ${GITHUB_ORG}
echo DOCKERHUB_USER=$DOCKERHUB_USER >> .env

gum confirm "
We need to create GitHub secret DOCKERHUB_TOKEN.
Choose \"No\" if you already have it.
" \
    && DOCKERHUB_TOKEN=$(gum input --placeholder "Please enter Docker Hub token (more info: https://docs.docker.com/docker-hub/access-tokens)." --password) \
    && gh secret set DOCKERHUB_TOKEN --body "$DOCKERHUB_TOKEN" --org ${GITHUB_ORG}

export KUBECONFIG=$PWD/kubeconfig.yaml
echo KUBECONFIG=$KUBECONFIG >> .env

################
# Google Cloud #
################

if [[ "$HYPERSCALER" == "google" ]]; then

    export USE_GKE_GCLOUD_AUTH_PLUGIN=True

    export PROJECT_ID=dot-$(date +%Y%m%d%H%M%S)
    echo PROJECT_ID=${PROJECT_ID} >> .env

    gcloud projects create ${PROJECT_ID}

    echo "
Please open https://console.cloud.google.com/marketplace/product/google/container.googleapis.com?project=${PROJECT_ID} in a browser and *ENABLE* the API."

    gum input --placeholder "
Press the enter key to continue."

    echo "
Please open https://console.cloud.google.com/apis/library/sqladmin.googleapis.com?project=${PROJECT_ID} in a browser and *ENABLE* the API."

    gum input --placeholder "
Press the enter key to continue."

    echo "
Please open https://console.cloud.google.com/marketplace/product/google/secretmanager.googleapis.com?project=${PROJECT_ID} in a browser and *ENABLE* the API."

    gum input --placeholder "
Press the enter key to continue."

    export SA_NAME=devops-toolkit

    export SA="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

    gcloud iam service-accounts create $SA_NAME --project ${PROJECT_ID}

    export ROLE=roles/admin

    gcloud projects add-iam-policy-binding --role $ROLE ${PROJECT_ID} --member serviceAccount:$SA

    gcloud iam service-accounts keys create gcp-creds.json --project ${PROJECT_ID} --iam-account $SA

    gcloud container get-server-config --region us-east1

    export K8S_VERSION=$(gum input --placeholder "Type a valid master version from the previous output.")

    echo K8S_VERSION=$K8S_VERSION >> .env

    gum spin --spinner line --title "Waiting for the container API to be enabled..." -- sleep 30

    gcloud container clusters create dot --project ${PROJECT_ID} --region us-east1 --machine-type n1-standard-4 --num-nodes 1 --cluster-version ${K8S_VERSION} --node-version ${K8S_VERSION}

    gcloud container clusters get-credentials dot --project ${PROJECT_ID} --region us-east1

    gum spin --spinner line --title "Waiting for the cluster to be available..." -- sleep 30

    kubectl create namespace crossplane-system

    kubectl --namespace crossplane-system create secret generic gcp-creds --from-file creds=./gcp-creds.json

    gcloud iam service-accounts --project ${PROJECT_ID} create external-secrets

    echo -ne '{"password": "YouWillNeverFindOut"}' | gcloud secrets --project ${PROJECT_ID} create production-postgresql --data-file=-

    gcloud secrets --project ${PROJECT_ID} add-iam-policy-binding production-postgresql --member "serviceAccount:external-secrets@${PROJECT_ID}.iam.gserviceaccount.com" --role "roles/secretmanager.secretAccessor"

    gcloud iam service-accounts --project ${PROJECT_ID} keys create account.json --iam-account=external-secrets@${PROJECT_ID}.iam.gserviceaccount.com

    kubectl create namespace external-secrets

    kubectl --namespace external-secrets create secret generic google --from-file=credentials=account.json

    yq --inplace ".spec.provider.gcpsm.projectID = \"${PROJECT_ID}\"" idp-demo/eso/secret-store-google.yaml

fi

#############
# Setup AWS #
#############

if [[ "$HYPERSCALER" == "aws" ]]; then

    echo

    AWS_ACCESS_KEY_ID=$(gum input --placeholder "AWS Access Key ID")

    AWS_SECRET_ACCESS_KEY=$(gum input --placeholder "AWS Secret Access Key")

    AWS_ACCOUNT_ID=$(gum input --placeholder "AWS Account ID")

    eksctl create cluster --config-file idp-demo/eksctl-config.yaml

    eksctl create addon --name aws-ebs-csi-driver --cluster dot --service-account-role-arn arn:aws:iam::$AWS_ACCOUNT_ID:role/AmazonEKS_EBS_CSI_DriverRole --force

    kubectl create namespace crossplane-system

    echo "[default]
aws_access_key_id = $AWS_ACCESS_KEY_ID
aws_secret_access_key = $AWS_SECRET_ACCESS_KEY
" >aws-creds.conf

    kubectl --namespace crossplane-system create secret generic aws-creds --from-file creds=./aws-creds.conf

    aws secretsmanager create-secret --name production-postgresql --region us-east-1 --secret-string '{"password": "YouWillNeverFindOut"}'

    kubectl create namespace external-secrets

    kubectl --namespace external-secrets create secret generic aws --from-literal access-key-id=$AWS_ACCESS_KEY_ID --from-literal secret-access-key=$AWS_SECRET_ACCESS_KEY

fi

###############
# Setup Azure #
###############

# TODO:

####################
# Setup Crossplane #
####################

helm repo add crossplane-stable https://charts.crossplane.io/stable

helm repo update

helm upgrade --install crossplane crossplane-stable/crossplane --namespace crossplane-system --create-namespace --wait

kubectl apply --filename idp-demo/crossplane-config/provider-kubernetes-incluster.yaml

kubectl apply --filename idp-demo/crossplane-config/config-sql.yaml

kubectl apply --filename idp-demo/crossplane-config/config-app.yaml

kubectl apply --filename idp-demo/crossplane-config/provider-$HYPERSCALER-official.yaml

kubectl wait --for=condition=healthy provider.pkg.crossplane.io --all --timeout=300s

if [[ "$HYPERSCALER" == "google" ]]; then
    gum style --foreground 212 --border-foreground 212 --border double --margin "1 2" --padding "2 4" \
        'GKE starts with a very small control plane.' \
        '
Since a lot of CRDs were installed, GKE is likely going to detect
that its control plane is too small for it and increase its size
automatically.' \
    '
As a result, you might experience delays or errors like
"connection refused" or "TLS handshake timeout2 (among others).' \
    '
If that happens, wait for a while (e.g., 1h) for the control
plane nodes to be automatically changed for larger ones.' \
    '
This issue will soon be resolved and, when that happens, I will
remove this message and the sleep command that follows.' \
    '
Grab a cup of coffee and watch an episode of your favorite
series on Netflix.'

    gum spin --spinner line --title "Waiting for GKE control plane nodes to resize (1h approx.)..." -- sleep 3600

    echo "apiVersion: gcp.upbound.io/v1beta1
kind: ProviderConfig
metadata:
  name: default
spec:
  projectID: ${PROJECT_ID}
  credentials:
    source: Secret
    secretRef:
      namespace: crossplane-system
      name: gcp-creds
      key: creds" \
    | kubectl apply --filename -
else
    kubectl apply --filename crossplane-config/provider-config-$HYPERSCALER-official.yaml
fi

#################
# Setup Traefik #
#################

helm upgrade --install traefik traefik --repo https://helm.traefik.io/traefik --namespace traefik --create-namespace --wait

if [[ "$HYPERSCALER" == "aws" ]]; then

    gum spin --spinner line --title "Waiting for the ELB DNS to propagate..." -- sleep 30

    INGRESS_HOSTNAME=$(kubectl --namespace traefik get service traefik --output jsonpath="{.status.loadBalancer.ingress[0].hostname}")

    INGRESS_HOST=$(dig +short $INGRESS_HOSTNAME) 

    # TODO: Remove
    gum input --placeholder "
Is $INGRESS_HOST a single IP?"

else

    INGRESS_HOST=$(kubectl --namespace traefik get service traefik --output jsonpath="{.status.loadBalancer.ingress[0].ip}")

fi

echo INGRESS_HOST=$INGRESS_HOST >> .env

####################
# Setup Kubernetes #
####################

yq --inplace ".server.ingress.hosts[0] = \"gitops.${INGRESS_HOST}.nip.io\"" idp-demo/argocd/helm-values.yaml

export REPO_URL=$(git config --get remote.origin.url)

yq --inplace ".spec.source.repoURL = \"${REPO_URL}\"" idp-demo/argocd/apps.yaml

yq --inplace ".spec.source.repoURL = \"${REPO_URL}\"" idp-demo/argocd/schema-hero.yaml

kubectl apply --filename idp-demo/k8s/namespaces.yaml

##############
# Setup Port #
##############

echo "
Open https://app.getport.io in a browser, register (if not already) and add the Kubernetes templates.
Ignore the "Kubernetes catalog template setup" step (we'll set it up later)."

gum input --placeholder "
Press the enter key to continue."

echo "
Follow the instructions from https://docs.getport.io/build-your-software-catalog/sync-data-to-catalog/git/github/self-hosted-installation#register-ports-github-app to install the Port's GitHub App."

gum input --placeholder "
Press the enter key to continue."

########################
# Setup GitHub Actions #
########################

yq --inplace ".on.workflow_dispatch.inputs.repo-user.default = \"${GITHUB_USER}\"" idp-demo/.github/workflows/create-app-db.yaml

yq --inplace ".on.workflow_dispatch.inputs.image-repo.default = \"docker.io/${DOCKERHUB_USER}\"" idp-demo/.github/workflows/create-app-db.yaml

cat idp-demo/port/backend-app-action.json \
    | jq ".[0].userInputs.properties.\"repo-org\".default = \"$GITHUB_ORG\"" \
    | jq ".[0].invocationMethod.org = \"$GITHUB_ORG\"" \
    > idp-demo/port/backend-app-action.json.tmp

mv port/backend-app-action.json.tmp port/backend-app-action.json

gh repo view --web

echo "
Open "Actions" and enable GitHub Actions."

gum input --placeholder "
Press the enter key to continue."

###########
# The End #
###########

gum style \
	--foreground 212 --border-foreground 212 --border double \
	--margin "1 2" --padding "2 4" \
	'The setup is almost finished.' \
    '
Execute "source .env" to set the environment variables.'
