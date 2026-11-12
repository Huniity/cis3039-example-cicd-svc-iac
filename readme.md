# Backend Service CI/CD Example

## Project

A TypeScript product API running on Azure Functions v4, with Terraform infrastructure and GitHub Actions deployment.

This is a demo: endpoints allow anonymous reads and writes, and products are stored in memory per worker. Changes disappear when the worker restarts and are not shared across instances. Add authentication and persistent storage before using it for real product data.

### Available Endpoints

- `GET /api/products` - List all products
- `POST /api/products` - Upsert (create or update) a product
- `PUT /api/products` - Upsert (create or update) a product

## CI/CD Features

The [GitHub Actions workflow](.github/workflows/build.yml) builds the app, checks Terraform, and deploys from `main`. Follow [Terraform and CI/CD](#terraform-and-cicd) for the recommended publishing route. The manual Azure setup below is an alternative; use one route per deployment to avoid creating duplicate resources.

## Local Setup

Use Node.js 22 and npm. Azure CLI, Terraform >= 1.5, and GitHub CLI (`gh`) are also needed for the publishing commands below. Azure Functions Core Tools v4 is installed by `npm ci` as a development dependency. The repository includes a VS Code dev container configuration.

1. Install dependencies:

```bash
npm ci
```

2. Create your local settings file:

Copy the template to create your local development settings:

```bash
cp local.settings.template.json local.settings.json
```

> **Note:** Never commit your `local.settings.json` to source control. The template is safe to share.

3. Build the project:

```bash
npm run build
```

## Local testing with curl

### Start the Function App

```bash
npm start
```

The function app will start on `http://localhost:7071`.

### List Products

Split the VS Code terminal so you can see the output from the locally running app whilst having a new shell prompt to make a test HTTP call:

```bash
curl -i http://localhost:7071/api/products
```

The fake repo initialises with some example data, so expect an array of products.

### Upsert a Product

Using the sample data file (and a new bash terminal):

```bash
curl -i -X POST http://localhost:7071/api/products \
  -H "Content-Type: application/json" \
  -d @samples/product-post.json
```

Repeating the list products call should now show the new item.

## Azure Setup

### Sign into Azure CLI

Prepare for using the az CLI commands.

1. Ensure you are signed in:

```bash
az login
az account show
```

You should see your account properties displayed if you are successfully signed in.

2. Ensure you know which locations (e.g. francecentral) you are permitted to use:

```bash
az policy assignment list \
  --query "[?name.contains(@, 'sys.regionrestriction')].parameters.listOfAllowedLocations.value | []" \
  -o tsv
```

### Create a Resource Group and Azure Function App

1. Create a resource group (if you do not already have one for this deployment):

```bash
az group create \
  --name <your-resource-group> \
  --location <permitted-location>
```

Remember to follow our naming convention, e.g. shopping-lab-ab47-rg

2. Create a storage account (required for Azure Functions):

```bash
az storage account create \
  --name <yourfuncstorageaccount> \
  --location <permitted-location> \
  --resource-group <your-resource-group> \
  --sku Standard_LRS
```

3. Create the Function App:

```bash
az functionapp create \
  --name <your-function-app> \
  --resource-group <your-resource-group> \
  --storage-account <yourfuncstorageaccount> \
  --consumption-plan-location <permitted-location> \
  --runtime node \
  --functions-version 4
```

### Publish the Project to Azure

Build and deploy your code to the Function App:

```bash
npm run build
npx --no-install func azure functionapp publish <your-function-app> --javascript
```

You can now access your endpoints at:

```
https://<your-function-app>.azurewebsites.net/api/products
```

### Configure CORS (if app needs to call this)

If needed, allow cross-domain calls from your app domain and/or localhost, for example:

```bash
az functionapp cors add \
  --name <your-function-app> \
  --resource-group <your-resource-group> \
  --allowed-origins http://localhost:5173
```

## Terraform and CI/CD

The `infra/` folder declares the same resources as the manual Azure Setup above (resource group, storage account, consumption plan, Function App, Application Insights). Resource names are generated as `<project>-<environment>-<random suffix>`, e.g. `shopping-lab-x7k2qm-rg`.

The workflow `.github/workflows/build.yml` runs `build` on pull requests and pushes. Pushes to `main` and manual runs on `main` also run `deploy`: Terraform applies the infrastructure, publishes the Functions app, and smoke-tests `GET /api/products`. Azure access uses GitHub OIDC with a user-assigned managed identity; no client secret is stored in GitHub. The `dev` environment must be limited to the `main` branch.

`npm test` currently prints a placeholder; CI verifies compilation and Terraform configuration, and deployment checks that `GET /api/products` responds successfully.

### One-time setup

Terraform state is stored in an Azure Storage container shared by CI and local Terraform runs. GitHub authenticates to Azure with OIDC using a user-assigned managed identity. The identity trusts only the `dev` GitHub environment and receives Contributor access to the subscription plus Storage Blob Data Contributor access to the state account. This avoids a long-lived client secret.

Sign in and choose the subscription that will host the app and Terraform state:

```bash
az login
gh auth login
az account set --subscription "<subscription-id>"
LOCATION=francecentral
SUB_ID=$(az account show --query id -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv)
```

Create a separate resource group and storage account for Terraform state. Choose a globally unique account name of 3–24 lowercase letters or digits. If these already exist, keep the existing values instead of creating duplicates.

```bash
TFSTATE_RG=shopping-lab-tfstate-rg
TFSTATE_SA=replacewithuniquename

az group create --name "$TFSTATE_RG" --location "$LOCATION"
az storage account create --name "$TFSTATE_SA" --resource-group "$TFSTATE_RG" \
  --location "$LOCATION" --sku Standard_LRS \
  --min-tls-version TLS1_2 --allow-blob-public-access false
az storage container-rm create --storage-account "$TFSTATE_SA" \
  --resource-group "$TFSTATE_RG" --name tfstate
```

Create the user-assigned managed identity and its GitHub trust. The subject below ties the identity to this repository's `dev` environment:

```bash
IDENTITY_NAME=shopping-lab-github-actions
az identity create --name "$IDENTITY_NAME" --resource-group "$TFSTATE_RG" \
  --location "$LOCATION" --output none

CLIENT_ID=$(az identity show --name "$IDENTITY_NAME" --resource-group "$TFSTATE_RG" \
  --query clientId -o tsv)
PRINCIPAL_ID=$(az identity show --name "$IDENTITY_NAME" --resource-group "$TFSTATE_RG" \
  --query principalId -o tsv)

az identity federated-credential create --name github-dev \
  --identity-name "$IDENTITY_NAME" --resource-group "$TFSTATE_RG" \
  --issuer https://token.actions.githubusercontent.com \
  --subject repo:Huniity/cis3039-example-cicd-svc-iac:environment:dev \
  --audiences api://AzureADTokenExchange

az role assignment create --assignee-object-id "$PRINCIPAL_ID" \
  --assignee-principal-type ServicePrincipal --role Contributor \
  --scope "/subscriptions/$SUB_ID"
TFSTATE_ID=$(az storage account show --name "$TFSTATE_SA" --resource-group "$TFSTATE_RG" \
  --query id -o tsv)
az role assignment create --assignee-object-id "$PRINCIPAL_ID" \
  --assignee-principal-type ServicePrincipal --role "Storage Blob Data Contributor" \
  --scope "$TFSTATE_ID"
```

In GitHub, create the **dev** environment under Settings > Environments if it does not exist. Restrict its deployment branches to the selected `main` branch. Under the environment's **Variables**, add these values (the `gh` CLI commands below do the same):

```bash
REPO=Huniity/cis3039-example-cicd-svc-iac
gh variable set AZURE_CLIENT_ID --repo "$REPO" --env dev --body "$CLIENT_ID"
gh variable set AZURE_TENANT_ID --repo "$REPO" --env dev --body "$TENANT_ID"
gh variable set AZURE_SUBSCRIPTION_ID --repo "$REPO" --env dev --body "$SUB_ID"
gh variable set AZURE_LOCATION --repo "$REPO" --env dev --body "$LOCATION"
gh variable set TFSTATE_RESOURCE_GROUP --repo "$REPO" --env dev --body "$TFSTATE_RG"
gh variable set TFSTATE_STORAGE_ACCOUNT --repo "$REPO" --env dev --body "$TFSTATE_SA"
# Optional: TFSTATE_CONTAINER (defaults to tfstate)
```

No GitHub secret is needed. The workflow receives a short-lived OIDC token only for jobs on `main` that target `dev`. Pull requests run the build and Terraform formatting/validation checks without Azure access.

### First publish and verification

Push a change to `main`, or manually run the workflow against `main`:

```bash
gh workflow run build.yml --ref main
gh run list --workflow build.yml --limit 5
```

The deploy job creates or updates Azure resources, publishes the app, and retries a GET request to the products endpoint. Terraform apply can create billable Azure resources.

After the run succeeds, find the URL from the workflow's Terraform output or from the Azure Function App Overview page. The endpoint is `https://<function-app>.azurewebsites.net/api/products`. Verify it with:

```bash
curl --fail-with-body -i "https://<function-app>.azurewebsites.net/api/products"
curl --fail-with-body -i -X POST "https://<function-app>.azurewebsites.net/api/products" \
  -H "Content-Type: application/json" \
  --data-binary @samples/product-post.json
```

GET returns a JSON array and POST returns the saved product with `updatedAt`. PUT accepts the same body. Products are in memory, so later reads may reach a different worker and changes disappear when a worker restarts.

If a deployment fails, inspect the failing Actions step. Common causes are missing environment variables, role-assignment propagation delay, a state backend name mismatch, or a region policy restriction. Application Insights is available in the generated resource group for runtime errors.

### Running Terraform locally

```bash
cd infra
cp backend.hcl.example backend.hcl   # fill in the same TFSTATE values
terraform init -backend-config=backend.hcl
terraform plan
```

For local overrides, copy `infra/terraform.tfvars.example` to `infra/terraform.tfvars` and edit it. Keep the location consistent with `AZURE_LOCATION` in CI. Local ignored `.tfvars` files are not available to GitHub Actions: the current workflow only passes the location override. Configure other shared overrides in tracked Terraform configuration or explicitly wire them into the workflow.

`product_updated_base_url` sets an app setting, but the current application does not send update events. `cors_allowed_origins` controls browser access; CORS does not provide authentication.

> If you previously applied with local state, run `terraform init -migrate-state -backend-config=backend.hcl` to move it into Azure instead of creating a second set of resources.
