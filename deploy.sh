#!/bin/bash

. ./defaults

function envs_show() {
  ( echo Environment,Cloud,Template,Created
  for e in $(find environments -type f); do
    ( . $e
    [[ ! "$DEP_TEMPLATE" ]] && DEP_TEMPLATE="<none>"
    echo $(basename $e | cut -f 2- -d -),$DEP_CLOUD,$DEP_TEMPLATE,$(perl -MPOSIX -e 'print strftime("%Y-%m-%d %H:%M:%S",gmtime((stat "'$e'")[10]))') )
  done ) | column -t -s,
  exit
}

function help_show() {
  cat <<EOF
usage: $0 [ options ]
  -h				print this usage and exit
  --envs			list environments
  --env=name			specify environment in which to deploy
  --ssh				SSH to the first master node of the specified environment
  --destroy			destroy VMs
  --platform=k8s|ocp3		deploy Kubernetes or Openshift 3.11 (default $DEP_PLATFORM)
  --clusters=num		number of clusters to deploy (default $DEP_CLUSTERS)
  --nodes=num			number of worker nodes in each cluster (default $DEP_NODES)
  --k8s_version=x.y.z		Kubernetes version to install (default $DEP_K8S_VERSION)
  --px_version=x.y.z		Portworx version to install (default $DEP_PX_VERSION)
  --aws_type=text		AWS instance type (default $AWS_TYPE)
  --aws_ebs="type:size ..."	AWS EBS volumes to be attached to each worker node (default "$AWS_EBS")
  --gcp_type=text		GCP instance type (default $GCP_TYPE)
  --gcp_disks="type: size..."	GCP disk volimes to be attached to each worker node (default "$GCP_DISKS")
  --template=name		name of template to deploy
Additional flags for initialisation:
  --region=name			specify AWS or GCP region (default $AWS_REGION or $GCP_REGION)
  --cloud=aws|gcp		deploy on AWS or Google Cloud (default $DEP_CLOUD)
  --sshkey=path			path to private SSH key associated with AWS IAM account or GCP project (default $DEP_SSHKEY)
  --aws_keypair=name		name of AWS keypair (default $AWS_KEYPAIR)

Examples:
  Deploy single K8s cluster on AWS:
    $0 --env=abcBank-Demo --region=us-west-3 --aws_keypair=myKeyPair

  Destroy the above example:
    $0 --env=abcBank-Demo --destroy

  Connect to the first master:
    $0 --env=abcBank-Demo --ssh

  Deploy a single K8s cluster with the defaults:
    $0 --env=abcBank-Demo

  Deploy a single clusterpair on Openshift and GCP:
    $0 --env=abcBank-Demo --template=clusterpair --cloud=gcp --platform=ocp3

  Deploy 3 Portworx clusters of 5 nodes on AWS:
    $0 --env=abcBank-Demo --template=px --clusters=3 --nodes=5
EOF
  exit
}

function env_del_aws {
  instances=$(aws ec2 describe-instances --region=$AWS_REGION --filters "Name=instance-state-name,Values=running" "Name=network-interface.vpc-id,Values=$_AWS_vpc" --query "Reservations[*].Instances[*].InstanceId" --output text)
  [[ "$instances" ]] && {
    aws ec2 terminate-instances --region $AWS_REGION --instance-ids $instances >/dev/null
    aws ec2 wait instance-terminated --region $AWS_REGION --instance-ids $instances
  }
  aws ec2 --region=$AWS_REGION delete-security-group --group-id $_AWS_sg &&
  aws ec2 --region=$AWS_REGION delete-subnet --subnet-id $_AWS_subnet &&
  aws ec2 --region=$AWS_REGION detach-internet-gateway --internet-gateway-id $_AWS_gw --vpc-id $_AWS_vpc &&
  aws ec2 --region=$AWS_REGION delete-internet-gateway --internet-gateway-id $_AWS_gw &&
  aws ec2 --region=$AWS_REGION delete-route-table --route-table-id $_AWS_routetable &&
  aws ec2 --region=$AWS_REGION delete-vpc --vpc-id $_AWS_vpc &&
  rm -f environments/$DEP_ENV
}

function env_del_gcp {
  gcloud projects delete $_GCP_project --quiet && rm -f environments/$DEP_ENV px-deploy_gcp_$_GCP_project.json
}

function env_create_aws {
  _AWS_vpc=$(aws --region=$AWS_REGION --output text ec2 create-vpc --cidr-block 192.168.0.0/16 --query Vpc.VpcId)
  _AWS_subnet=$(aws --region=$AWS_REGION --output text ec2 create-subnet --vpc-id $_AWS_vpc --cidr-block 192.168.0.0/16 --query Subnet.SubnetId)
  _AWS_gw=$(aws --region=$AWS_REGION --output text ec2 create-internet-gateway --query InternetGateway.InternetGatewayId)
  aws --region=$AWS_REGION ec2 attach-internet-gateway --vpc-id $_AWS_vpc --internet-gateway-id $_AWS_gw
  _AWS_routetable=$(aws --region=$AWS_REGION --output text ec2 create-route-table --vpc-id $_AWS_vpc --query RouteTable.RouteTableId)
  aws --region=$AWS_REGION ec2 create-route --route-table-id $_AWS_routetable --destination-cidr-block 0.0.0.0/0 --gateway-id $_AWS_gw >/dev/null
  aws --region=$AWS_REGION ec2 associate-route-table  --subnet-id $_AWS_subnet --route-table-id $_AWS_routetable >/dev/null
  _AWS_sg=$(aws --region=$AWS_REGION --output text ec2 create-security-group --group-name px-cloud --description "Security group for px-cloud" --vpc-id $_AWS_vpc --query GroupId)
  aws --region=$AWS_REGION ec2 authorize-security-group-ingress --group-id $_AWS_sg --protocol tcp --port 22 --cidr 0.0.0.0/0 &
  aws --region=$AWS_REGION ec2 authorize-security-group-ingress --group-id $_AWS_sg --protocol tcp --port 443 --cidr 0.0.0.0/0 &
  aws --region=$AWS_REGION ec2 authorize-security-group-ingress --group-id $_AWS_sg --protocol tcp --port 8080 --cidr 0.0.0.0/0 &
  aws --region=$AWS_REGION ec2 authorize-security-group-ingress --group-id $_AWS_sg --protocol tcp --port 30000-32767 --cidr 0.0.0.0/0 &
  aws --region=$AWS_REGION ec2 authorize-security-group-ingress --group-id $_AWS_sg --protocol all --cidr 192.168.0.0/16 &
  aws --region=$AWS_REGION ec2 create-tags --resources $_AWS_vpc $_AWS_subnet $_AWS_gw $_AWS_routetable $_AWS_sg --tags Key=px-deploy_name,Value=$DEP_ENV &
  _AWS_ami=$(aws --region=$AWS_REGION --output text ec2 describe-images --owners 679593333241 --filters Name=name,Values='CentOS Linux 7 x86_64 HVM EBS*' Name=architecture,Values=x86_64 Name=root-device-type,Values=ebs --query 'sort_by(Images, &Name)[-1].ImageId')
  wait
  set | grep -E '^(DEP|AWS|_AWS)' | grep -v GCP >environments/$DEP_ENV
}

function env_create_gcp {
  _GCP_project=pxd-$(uuidgen | tr -d -- - | cut -b 1-26 | tr 'A-Z' 'a-z')
  gcloud projects create $_GCP_project --labels px-deploy_name=$DEP_ENV
  account=$(gcloud alpha billing accounts list | tail -1 | cut -f 1 -d " ")
  gcloud alpha billing projects link $_GCP_project --billing-account $account
  gcloud services enable compute.googleapis.com --project $_GCP_project
  gcloud compute networks create px-net --project $_GCP_project
  gcloud compute networks subnets create --range 192.168.0.0/16 --network px-net px-subnet --region $GCP_REGION --project $_GCP_project
  gcloud compute firewall-rules create allow-internal --allow=tcp,udp,icmp --source-ranges=192.168.0.0/16 --network px-net --project $_GCP_project &
  gcloud compute firewall-rules create allow-external --allow=tcp:22,tcp:443,tcp:6443 --network px-net --project $_GCP_project &
  gcloud compute project-info add-metadata --metadata "ssh-keys=$USER:$(cat $DEP_SSHKEY.pub)" --project $_GCP_project &
  service_account=$(gcloud iam service-accounts list --project $_GCP_project --format 'flattened(email)' | tail -1 | cut -f 2 -d " ")
  _GCP_key=$(gcloud iam service-accounts keys create /dev/stdout --iam-account $service_account | base64)
  wait
  set | grep -E '^(DEP|GCP|_GCP)' | grep -v AWS >environments/$DEP_ENV
}


options=$(getopt -o dnh --long envs,env:,ssh,region:,aws_keypair:,sshkey:,platform:,cloud:,clusters:,nodes:,k8s_version:,px_version:,aws_type:,aws_ebs:,gcp_type:,gcp_disks,gcp_zone:,template:,destroy -- "$@")
[ $? -eq 0 ] || { 
  echo "Incorrect options provided"
  exit 1
}

eval set -- "$options"
while true; do
  case "$1" in
  -h)
    DEP_HELP=1
    break
    ;;
  --template)
    shift;
    DEP_TEMPLATE=$1
    [[ ! -f "templates/$DEP_TEMPLATE" ]] && {
      echo "Bad template"
      exit 1
    }
    ;;
  --)
    shift
    break
    ;;
  esac
  shift
done
[[ $DEP_TEMPLATE ]] && . templates/$DEP_TEMPLATE

eval set -- "$options"
while true; do
  case "$1" in
  --envs)
    DEP_ENVS=1
    ;;
  --destroy)
    DEP_DESTROY=1
    ;;
  --env)
    shift;
    DEP_ENV=$1
    [[ ! $DEP_ENV =~ ^[a-zA-Z0-9_\-]+$ ]] && {
      echo "Bad environment name"
      exit 1
    }
    ;;
  --ssh)
    DEP_SSH=1
    ;;
  --region)
    shift;
    AWS_REGION=$1
    GCP_REGION=$1
    [[ ! "$AWS_REGION" =~ ^[a-zA-Z0-9_\-]+$ ]] && {
      echo "Bad region"
      exit 1
    }
    ;;
  --aws_keypair)
    shift;
    AWS_KEYPAIR=$1
    [[ ! "$AWS_KEYPAIR" =~ ^[a-zA-Z0-9_\-]+$ ]] && {
      echo "Bad keypair name"
      exit 1
    }
    ;;
  --sshkey)
    shift;
    DEP_SSHKEY=$1
    [[ ! -f "$DEP_SSHKEY" ]] && {
      echo "Bad SSH key"
      exit 1
    }
    ;;
  --platform)
    shift;
    DEP_PLATFORM=$1
    [[ ! $DEP_PLATFORM =~ ^k8s|ocp3$ ]] && {
      echo "Bad platform"
      exit 1
    }
    ;;
  --cloud)
    shift;
    DEP_CLOUD=$1
    [[ ! $DEP_CLOUD =~ ^aws|gcp$ ]] && {
      echo "Bad cloud"
      exit 1
    }
    ;;
  --clusters)
    shift;
    DEP_CLUSTERS=$1
    [[ ! $DEP_CLUSTERS =~ ^[0-9]+$ ]] && {
      echo "Bad clusters"
      exit 1
    }
    ;;
  --nodes)
    shift;
    DEP_NODES=$1
    [[ ! $DEP_NODES =~ ^[0-9]+$ ]] && {
      echo "Bad nodes"
      exit 1
    }
    ;;
  --k8s_version)
    shift;
    DEP_K8S_VERSION=$1
    [[ ! $DEP_K8S_VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && {
      echo "Bad Kubernetes version"
      exit 1
    }
    ;;
  --px_version)
    shift;
    DEP_PX_VERSION=$1
    [[ ! $DEP_PX_VERSION =~ ^[0-9\.]+$ ]] && {
      echo "Bad Portworx version"
      exit 1
    }
    ;;
  --aws_type)
    shift;
    AWS_TYPE=$1
    [[ ! $AWS_TYPE =~ ^[0-9a-z\.]+$ ]] && {
      echo "Bad AWS type"
      exit 1
    }
    ;;
  --aws_ebs)
    shift;
    AWS_EBS=$1
    [[ ! $AWS_EBS =~ ^[0-9a-z\ :]+$ ]] && {
      echo "Bad AWS EBS volumes"
      exit 1
    }
    ;;
  --gcp_type)
    shift;
    GCP_TYPE=$1
    [[ ! $GCP_TYPE =~ ^[0-9a-z\-]+$ ]] && {
      echo "Bad GCP type"
      exit 1
    }
    ;;
  --gcp_disks)
    shift;
    GCP_DISKS=$1
    [[ ! $GCP_DISKS =~ ^[0-9a-z\ :\-]+$ ]] && {
      echo "Bad GCP disks"
      exit 1
    }
    ;;
  --gcp_zone)
    shift;
    GCP_ZONE=$1
    [[ ! $GCP_ZONE =~ ^a|b|c$ ]] && {
      echo "Bad GCP zone"
      exit 1
    }
    ;;
  --)
    shift
    break
    ;;
  esac
  shift
done

[[ ! -d environments ]] && mkdir environments
[[ "$DEP_HELP" ]] && help_show
[[ "$DEP_ENVS" ]] && envs_show

[[ "$DEP_SSH" ]] && {
  [[ ! "$DEP_ENV" ]] && echo Must specify --env for SSH && exit
  [[ ! -f "environments/$DEP_ENV" ]] && echo Environment $DEP_ENV does not exist && exit
  . environments/$DEP_ENV
  export $(set | grep -E '^(DEP|AWS|GCP|_AWS|_GCP)' | cut -f 1 -d = )
  [[ "$DEP_CLOUD" == aws ]] && ip=$(aws ec2 describe-instances --region $AWS_REGION --filters "Name=network-interface.vpc-id,Values=$_AWS_vpc" "Name=tag:Name,Values=master-1" "Name=instance-state-name,Values=running" --query "Reservations[*].Instances[*].PublicIpAddress" --output text)
  [[ "$DEP_CLOUD" == gcp ]] && ip=$(gcloud compute instances list --project $_GCP_project --filter="name=('master-1')" --format 'flattened(networkInterfaces[0].accessConfigs[0].natIP)' | tail -1 | cut -f 2 -d " ")
  ssh -oStrictHostKeyChecking=no -i id_rsa root@$ip
  exit
}

if [ "$DEP_DESTROY" ]; then
  [[ ! "$DEP_ENV" ]] && echo Must specify --env for destroy && exit
  [[ ! -f "environments/$DEP_ENV" ]] && echo Environment $DEP_ENV does not exist && exit
  . environments/$DEP_ENV
  #export $(set | grep -E '^(DEP|AWS|GCP|_AWS|_GCP)' | cut -f 1 -d = )
  env_del_$DEP_CLOUD
else
  if [[ "$DEP_ENV" ]]; then
    [[ -e "environments/$DEP_ENV" ]] && echo Environment $DEP_ENV already exists && exit
  else
    DEP_ENV=$(uuidgen)
  fi
  #export DEP_ENV
  env_create_$DEP_CLOUD
  #. environments/$DEP_ENV
  export $(set | grep -E '^(DEP|AWS|GCP|_AWS|_GCP)' | cut -f 1 -d = )
  vagrant up
  rm -rf .vagrant
fi
