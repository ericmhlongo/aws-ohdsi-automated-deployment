#!/bin/bash
# Copyright 2018 Amazon.com, Inc. or its affiliates. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License"). You may not use this file except in compliance with the License. 
# A copy of the License is located at
#    http://aws.amazon.com/apache2.0/
# or in the "license" file accompanying this file. This file is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, 
# either express or implied. See the License for the specific language governing permissions and limitations under the License.
#
#
#  This script configures the CFN deployed environment for OHDSI WebAPI and Atlas
#
#  Requirements: 
#  $RDS_ENDPOINT must contain the endpoint of the Postgres Aurora RDS environment to be used to store the WebAPI application data
#  $EB_ENDPOINT must contain the endpoint of the Elastic Beanstalk Tomcat environment
#  $REDSHIFT_ENDPOINT must contain the endpoint of the Redshift Cluster used for OMOP CDM and Vocabulary
#  $ACCT_ID must contain the AWS Account ID for the account in which this environment is being deployed
#  $BUCKET_NAME must contain the s3 bucket name in which Elastic Beanstalk will look for the ohdsi-webapi-atlas.zip file
#  $DATABASE_PASSWORD must contain the password that was used for the master accounts for Redshift and RDS Aurora Postgres
#  $RS_ROLE_ARN must contain the role ARN that allows Redshift to read the sample data from S3.

echo "RDS_ENDPOINT=" $RDS_ENDPOINT
echo "EB_ENDPOINT=" $EB_ENDPOINT
echo "REDSHIFT_ENDPOINT=" $REDSHIFT_ENDPOINT
echo "ACCT_ID=" $ACCT_ID
echo "BUCKET_NAME=" $BUCKET_NAME
echo "DATABASE_PASSWORD=" $DATABASE_PASSWORD
echo "RS_ROLE_ARN=" $RS_ROLE_ARN
export AWS_DEFAULT_REGION=$(echo $EB_ENDPOINT | cut -d . -f2)

#Deploy the OMOP CDM Schema to Redshift
export PGPASSWORD=$DATABASE_PASSWORD
psql -d mycdm --host=$REDSHIFT_ENDPOINT --port=5439 -U master -a -f "./OMOP CDM ddl - Redshift.sql"
psql -d mycdm --host=$REDSHIFT_ENDPOINT --port=5439 -U master -a -f results_schema.sql

#Deploy the CMS De-SynPUF sample data into the OMOP CDM
sed -i 's!'ACCT_ID'!'$ACCT_ID'!' load_cms-cdm.sql
sed -i 's!'RS_ROLE_ARN'!'$RS_ROLE_ARN'!' load_cms-cdm.sql 
psql -d mycdm --host=$REDSHIFT_ENDPOINT --port=5439 -U master -a -f load_cms-cdm.sql


#Deploy the SNOMED v5 Vocabulary into the OMOP CDM
sed -i 's!'ACCT_ID'!'$ACCT_ID'!' load_vocabulary.sql
sed -i 's!'RS_ROLE_ARN'!'$RS_ROLE_ARN'!' load_vocabulary.sql
psql -d mycdm --host=$REDSHIFT_ENDPOINT --port=5439 -U master -a -f load_vocabulary.sql


#Wait for the WebAPI app to be deployed by Elastic Beanstalk and populate the tables in RDS Postrgres
while [ `curl http://$EB_ENDPOINT 1> /dev/null 2> /dev/null; echo $?` -ne 0 ]
do
	sleep 5
done
sed -i 's!REDSHIFT_ENDPOINT!'$REDSHIFT_ENDPOINT'!' postgres_init_sources.sql
sed -i 's!DATABASE_PASSWORD!'$DATABASE_PASSWORD'!' postgres_init_sources.sql

#Load the sources reference table into the WebAPI Postgres database
export PGPASSWORD="admin1"
psql -d OHDSI --host=$RDS_ENDPOINT --port=5432 -U ohdsi_admin_user -a -f postgres_init_sources.sql
aws elasticbeanstalk restart-app-server --environment-name $(echo $EB_ENDPOINT | cut -d . -f1)


#Run Achilles R script to enabled Data Source visualization
sed -i 's!REDSHIFT_ENDPOINT!'$REDSHIFT_ENDPOINT'!' achilles.r
sed -i 's!DATABASE_PASSWORD!'$DATABASE_PASSWORD'!' achilles.r
yum -y install openssl-devel
yum -y install libcurl-devel
sudo yum-config-manager --disable amzn-updates
yum -y install R
Rscript achilles.r 