
# In this script, automatically throw exceptions on cmdlets that return error codes.
# This is so we don't have to issue "-ErrorAction Stop" on (almost) every cmdlet.
$ErrorActionPreference = 'Stop'
# Non-cmdlet commands like 'aws' don't throw exceptions on error codes.
# For those, we have to check $LASTEXITCODE.




# This is the domain we are working with. It has to be in a hosted zone in Route53 for 
# the AWS account that is being used. This hosted zone has to be created before running
# this script. The name servers in the 'Hosted Zone Details' for this domain should
# point to the correct name servers for the domain. These are listed in NS and SOA records.
# Be sure to delete all records in the hosted zone except the NS and SOA records.
$domain = 'trivelli.org'
$zone_id = (aws route53 list-hosted-zones --query "HostedZones[?Name=='${domain}.'].Id" --output text) -replace '^/hostedzone/', ''
# list all domains and zone-id's with this...
# aws route53 list-hosted-zones --query "HostedZones[*].[Name, Id]" --output table
if ($LASTEXITCODE -eq 0) {
    Write-Host "For domain '${domain}' zone_id ${zone_id}"
} else {
    Write-Host "Could not get zone_id for domain '${domain}', err code = ${LASTEXITCODE}."
    exit 1
}


# witch.js is a lambda function that is used to copy the static content for the website.
# It is a nodejs function that copies files from one s3 bucket to another.
# The source bucket is going to be the temp_bucket that we create in the next stanza. The
# destination bucket will be the rootbucket for the website. The rootbucket is created by
# the cloudformation template, cloudfront-site.yaml.

# This just installs nodejs npm library dependencies for witch.js and packages it 
# all into a zip file, witch.zip.
try {
    Remove-Item -Path .\witch.zip -Force -ErrorAction SilentlyContinue
    Push-Location -Path .\source\witch
    Remove-Item -Path .\nodejs -Recurse -Force -ErrorAction SilentlyContinue
    npm install --prefix nodejs mime-types
    if ($LASTEXITCODE -ne 0) {
        throw "npm install failed, err code = ${LASTEXITCODE}"
    } 
    Copy-Item -Path .\witch.js -Destination .\nodejs\node_modules\witch.js
    Compress-Archive -Path .\nodejs -DestinationPath ..\..\witch.zip -Force
} catch {
    Write-Host "Could not package lambda function, err code = ${LASTEXITCODE}."
    exit 2
} finally {
    Pop-Location
}


# Create a staging bucket for templates.
# For a domain of 'example.com', the bucket name will be 'example-<guid8>' 
# where <guid8> is the first 8 characters of a new guid. 
$temp_bucket = $domain.Split('.')[0] + '-' + (New-Guid).Guid.ToString().Split('-')[0]
aws s3 mb "s3://${temp_bucket}"

if ($LASTEXITCODE -eq 0) {
    Write-Host "Created s3://${temp_bucket}"
} else {
    Write-Host "Could not create s3://${temp_bucket}, err code = $LASTEXITCODE."
    exit 3
}
# if you want to remove temp_bucket later...
# aws s3 rm s3://your-bucket-name --recursive

# Also use bucket name as the stack name!
$stack_name = $temp_bucket



# Creates a packaged template and uploads the template and its resources to an s3 bucket, 
# temp_bucket. This is a staging operation in preparation for the actual deployment of the stack.
# All local resources which are referenced in the CF templates (eg witch.zip and www/ folder) get
# uploaded to the temp_bucket in s3. Their references in the CF templates are updated to point
# to the s3 URL for each resource. The resulting template is called packaged.template.
aws --region us-east-1 cloudformation package `
    --template-file templates/main.yaml `
    --s3-bucket $temp_bucket `
    --output-template-file .\packaged.template

if ($LASTEXITCODE -eq 0) {
    Write-Host "Created packaged.template"
} else {
    Write-Host "Could not create packaged.template, err code = $LASTEXITCODE."
    exit 4
}



# Actually deploy the stack. This takes some time!
aws --region us-east-1 cloudformation deploy `
    --stack-name $stack_name `
    --template-file packaged.template `
    --capabilities CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND `
    --parameter-overrides  DomainName=$domain SubDomain=www HostedZoneId=$zone_id CreateApex=yes

if ($LASTEXITCODE -eq 0) {
    Write-Host "Deployed stack 'trivelli'"
} else {
    Write-Host "Could not deploy stack 'trivelli', err code = $LASTEXITCODE."
    exit 5
}


# clean up temp_bucket. Do I want to do this? I think so.
aws s3 rm "s3://${temp_bucket}" --recursive

if ($LASTEXITCODE -eq 0) {
    Write-Host "Cleaned up s3://${temp_bucket}"
} else {
    Write-Host "Could not clean up s3://${temp_bucket}, err code = $LASTEXITCODE."
    exit 6
}


