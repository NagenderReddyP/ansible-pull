#!/bin/bash
#set -ex

#  --------------------------------------------
#  ------ Preparing a naked RHEL8 ec2 ---------
#  --------------------------------------------
TOKEN=$(curl -X PUT "http://instance-data/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")

INSTANCE_ID="$(curl -H "X-aws-ec2-metadata-token: $TOKEN" -v http://instance-data/latest/meta-data/instance-id)"
     REGION="$(curl -H "X-aws-ec2-metadata-token: $TOKEN" -v http://instance-data/latest/meta-data/placement/region)"
        CLI="/aws/dist/aws"
        Env=$($CLI ec2 describe-tags --filters "Name=resource-id,Values=$INSTANCE_ID" "Name=key,Values=AwsEnv"  --region $REGION --output=text |cut -f5| awk '{print tolower($0)}')
        Prj=$($CLI ec2 describe-tags --filters "Name=resource-id,Values=$INSTANCE_ID" "Name=key,Values=Project" --region $REGION --output=text |cut -f5| awk '{print tolower($0)}')
#dnf update -y

# Disable selinux (needed for Cognos)
sed -i 's/^SELINUX=.*$/SELINUX=disabled/' /etc/selinux/config
setenforce 0 || true
dnf install -y unzip jq ansible

# -----------------------------------------------------------
# Download and install AWS BINARIES (ssm, cloudwatch, awscli)
# -----------------------------------------------------------
for File in \
s3.amazonaws.com/ec2-downloads-windows/SSMAgent/latest/linux_amd64/amazon-ssm-agent.rpm \
s3.amazonaws.com/amazoncloudwatch-agent/redhat/amd64/latest/amazon-cloudwatch-agent.rpm
do
    F="/tmp/$(basename $File)"
    ext=$(echo $F|sed 's/^.*\.//g')

    curl "https://$File"     -o $F

        case $ext in
                rpm) dnf install -y $F ;; # https://www.cyberciti.biz/faq/unable-to-read-consumer-identity-rhn-yum-warning/
                zip) unzip       -q $F ;;
        esac
        rm                     -f $F
done

# -----------------------------------
# AWSCI SETUP
# -----------------------------------
#sh /aws/install

# -----------------------------------
# SSM START
# -----------------------------------
systemctl enable amazon-ssm-agent
systemctl start amazon-ssm-agent

# -----------------------------------
# CLOUDWATCH START
# -----------------------------------
CLOUDWATCH_CONFIG="/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.d/file_config.json"

$CLI ssm get-parameters --region $REGION --names AmazonCloudWatch-Agent-Linux-ec2 | jq '.Parameters[0].Value | fromjson' > "$CLOUDWATCH_CONFIG"

sed -i -e "s#Project#${Prj}#g" -e "s#Environement#${Env}#g" -e 's#"timezone": "Local"#"timezone": "Local",\n "retention_in_days": 30#g' "$CLOUDWATCH_CONFIG"

/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -c file:"$CLOUDWATCH_CONFIG" -s

systemctl enable amazon-cloudwatch-agent
systemctl start amazon-cloudwatch-agent

# ----------------------------------------------------------------------
# -------------------- CONFIGUGRE AND START COGNOS PLAYBOOK ------------
# ----------------------------------------------------------------------

# Environnement variables needed for the Cognos Playbook
InstanceName=$($CLI ec2 describe-tags --filters "Name=resource-id,Values=$INSTANCE_ID" "Name=key,Values=Name" --region $REGION --output=text |cut -f5 )
PlaybookRpo="https://github.com/esteban-santiago/ansible-pull.git"

#Compose the parameter we want to search the value in the AWS ssm Parameter Store
CM_ALB_ParameterStore="creport-${Env}-ALB-content-mgr"
CM_EFS_ParameterStore="creport-${Env}-EFS-content-mgr"

#Get the value of the parameter in the parameter store
CM_ALB_endpoint=$($CLI ssm get-parameter --name "${CM_ALB_ParameterStore}" --with-decryption --region "$REGION" --query Parameter.Value --output text)
CM_EFS_endpoint=$($CLI ssm get-parameter --name "${CM_EFS_ParameterStore}" --with-decryption --region "$REGION" --query Parameter.Value --output text)

FQDN=$(hostname -f)
IPV4=$(hostname -I)

$CLI --region $REGION ec2 describe-instances --filters "Name=instance-state-name,Values=running" "Name=tag:Name,Values=creport-${Env}-EC2-analytics" --query 'Reservations[*].Instances[*].[PrivateIpAddress]' --output text | sort > /tmp/IPs.v4
PrimaryAnalytic=$(head -1 /tmp/IPs.v4)
SecundaryAnalytic=$(tail -1 /tmp/IPs.v4)

ExtraVars="Prj=$Prj Env=$Env Aws_Region=$REGION CM_ALB_endpoint=${CM_ALB_endpoint} CM_EFS_endpoint=${CM_EFS_endpoint} $FQDN=$FQDN IPV4=$IPV4 PrimaryAnalytic=$PrimaryAnalytic SecundaryAnalytic=$SecundaryAnalytic"
echo "ExtraVars Parameters [ $ExtraVars ] $PlaybookRpo $InstanceName"

#Give to the ansible playbook using –extra-vars, the value retrieved in the parameter store
echo ansible -U $PlaybookRpo $InstanceName --extra-vars "$ExtraVars"