"""The stack template and the project Dockerfile `morca aws` writes out:
deploy/aws/morca.yaml and deploy/project.Dockerfile, embedded by
scripts/embed-aws.py. Edit those, then run it; `pixi run test-aws-assets`
fails while this is out of date.
"""

comptime STACK_TEMPLATE: StaticString = """# morca on AWS with the ec2 runner (DESIGN.md, phase 5, PR 5b): one stack,
# so it's reviewed as one file and deleted as one stack.
#
# - a VPC with one public subnet in the Availability Zone given, and a
#   gateway endpoint for S3;
# - the control instance: the scheduler (MORCA_RUNNER=ec2), Postgres and
#   morca ui as containers, Caddy in front with a Let's Encrypt certificate;
#   in one of two slots, blue and green, so that morca aws replace-control
#   can boot a new one from this template beside it and move the Elastic
#   IP (DESIGN.md, "Replacing the control instance");
# - what runs need: a bucket for the warehouse and logs, a repository for
#   the image, a role and profile for run instances, a security group they
#   share;
# - a bucket for the lake, mlake-public-<account>: the warehouse,
#   MORCA_WAREHOUSE, is in it; morca's own bucket keeps the logs. It's private
#   unless PublicData is true, when anyone may read it unsigned (the
#   project's resource control policy refuses other accounts' signed
#   requests), billed to the project at S3's egress price;
# - the console's hostname, served by the same Caddy from a container
#   named console on port 8080, once one runs;
# - a Budgets alert.
#
# morca ui is public for reading, as a demo is; its actions need a login
# (morca user add, in the scheduler's container). Nothing else accepts a
# connection from outside: Postgres takes the run instances' only, and the
# instances take each other's only.
AWSTemplateFormatVersion: "2010-09-09"
Description: morca with the ec2 runner, a control instance and runs on instances of their own

Parameters:
  AvailabilityZone:
    Type: AWS::EC2::AvailabilityZone::Name
    Default: us-east-2a
  ControlInstanceType:
    Type: String
    Default: t4g.large
  AllowedRunTypes:
    Type: CommaDelimitedList
    Default: "c7g.large,c7g.xlarge,c7g.2xlarge,c7g.4xlarge,t4g.medium,t4g.large"
    Description: The only instance types the scheduler may start
  Ami:
    Type: AWS::SSM::Parameter::Value<AWS::EC2::Image::Id>
    Default: /aws/service/ecs/optimized-ami/amazon-linux-2023/arm64/recommended/image_id
    Description: arm64 Amazon Linux 2023 with Docker, for the control and run instances
  ImageTag:
    Type: String
    Default: latest
    Description: The tag of the morca image the control instance starts with (morca aws push pushes latest)
  ConsoleHostname:
    Type: String
    Default: libs.mlake.dev
    Description: The console app's hostname, an A record to PublicAddress; empty for none
  Hostname:
    Type: String
    Default: orca-demo.mlake.dev
    Description: The UI's public name, an A record to PublicAddress; it answers at <PublicAddress>.sslip.io too
  DbPassword:
    Type: String
    NoEcho: true
    MinLength: 16
    # It goes into a shell script and a URL as it is.
    AllowedPattern: "[A-Za-z0-9]+"
  BudgetEmail:
    Type: String
  PublicData:
    Type: String
    Default: "false"
    AllowedValues: ["true", "false"]
    Description: Whether anyone may read the lake's bucket unsigned; downloads are billed to the project
  BudgetDollars:
    Type: Number
    Default: 100
  ControlEnv:
    Type: String
    Default: ""
    # It goes into a shell script in single quotes.
    AllowedPattern: "[^']*"
    Description: The control instance's settings beyond the template's, KEY=VALUE entries separated by ";" (morca aws up --env); never a secret
  ActiveControl:
    Type: String
    Default: blue
    AllowedValues: [blue, green]
    Description: The control slot the Elastic IP is on (morca aws replace-control moves it)
  BlueSlot:
    Type: String
    Default: "true"
    AllowedValues: ["true", "false"]
    Description: Whether slot blue (Control) has an instance
  GreenSlot:
    Type: String
    Default: "false"
    AllowedValues: ["true", "false"]
    Description: Whether slot green (ControlGreen) has an instance
  BlueAmi:
    Type: String
    Default: ""
    Description: Slot blue's image id, pinned; empty for Ami's
  GreenAmi:
    Type: String
    Default: ""
    Description: Slot green's image id, pinned; empty for Ami's

Rules:
  ActiveSlotHasAnInstance:
    Assertions:
      - Assert: !Or
          - !And [!Equals [!Ref ActiveControl, blue], !Equals [!Ref BlueSlot, "true"]]
          - !And [!Equals [!Ref ActiveControl, green], !Equals [!Ref GreenSlot, "true"]]
        AssertDescription: The slot ActiveControl names has to have an instance (BlueSlot or GreenSlot true)

Conditions:
  Public: !Equals [!Ref PublicData, "true"]
  BlueOn: !Equals [!Ref BlueSlot, "true"]
  GreenOn: !Equals [!Ref GreenSlot, "true"]
  GreenActive: !Equals [!Ref ActiveControl, green]
  BlueAmiPinned: !Not [!Equals [!Ref BlueAmi, ""]]
  GreenAmiPinned: !Not [!Equals [!Ref GreenAmi, ""]]

Resources:
  Vpc:
    Type: AWS::EC2::VPC
    Properties:
      CidrBlock: 10.42.0.0/16
      EnableDnsHostnames: true
      EnableDnsSupport: true
      Tags: [{Key: Name, Value: orca}]
  Subnet:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref Vpc
      CidrBlock: 10.42.0.0/20
      AvailabilityZone: !Ref AvailabilityZone
      MapPublicIpOnLaunch: true
      Tags: [{Key: Name, Value: orca}]
  Gateway:
    Type: AWS::EC2::InternetGateway
  GatewayAttachment:
    Type: AWS::EC2::VPCGatewayAttachment
    Properties: {VpcId: !Ref Vpc, InternetGatewayId: !Ref Gateway}
  Routes:
    Type: AWS::EC2::RouteTable
    Properties: {VpcId: !Ref Vpc}
  DefaultRoute:
    Type: AWS::EC2::Route
    DependsOn: GatewayAttachment
    Properties: {RouteTableId: !Ref Routes, DestinationCidrBlock: 0.0.0.0/0, GatewayId: !Ref Gateway}
  SubnetRoutes:
    Type: AWS::EC2::SubnetRouteTableAssociation
    Properties: {SubnetId: !Ref Subnet, RouteTableId: !Ref Routes}
  # S3 traffic stays in the region, and costs nothing.
  S3Endpoint:
    Type: AWS::EC2::VPCEndpoint
    Properties:
      VpcId: !Ref Vpc
      ServiceName: !Sub com.amazonaws.${AWS::Region}.s3
      VpcEndpointType: Gateway
      RouteTableIds: [!Ref Routes]

  Bucket:
    Type: AWS::S3::Bucket
    Properties:
      BucketName: !Sub orca-${AWS::AccountId}-${AWS::Region}
      PublicAccessBlockConfiguration:
        BlockPublicAcls: true
        BlockPublicPolicy: true
        IgnorePublicAcls: true
        RestrictPublicBuckets: true
      BucketEncryption:
        ServerSideEncryptionConfiguration:
          - ServerSideEncryptionByDefault: {SSEAlgorithm: AES256}
      LifecycleConfiguration:
        Rules:
          - {Id: logs, Status: Enabled, Prefix: logs/, ExpirationInDays: 30}
          # The control instance's samples, a file a day (morca.system).
          - {Id: control, Status: Enabled, Prefix: logs/control/, ExpirationInDays: 14}
  # The lake's tables; anyone may read them when PublicData is true.
  # Account-level Block Public Access, if it's on, refuses the policy below.
  PublicBucket:
    Type: AWS::S3::Bucket
    Properties:
      BucketName: !Sub mlake-public-${AWS::AccountId}
      OwnershipControls:
        Rules: [{ObjectOwnership: BucketOwnerEnforced}]
      PublicAccessBlockConfiguration:
        BlockPublicAcls: true
        IgnorePublicAcls: true
        BlockPublicPolicy: !If [Public, false, true]
        RestrictPublicBuckets: !If [Public, false, true]
      BucketEncryption:
        ServerSideEncryptionConfiguration:
          - ServerSideEncryptionByDefault: {SSEAlgorithm: AES256}
      # Browsers, such as DuckDB in a page, read it too.
      CorsConfiguration:
        CorsRules:
          - {AllowedMethods: [GET, HEAD], AllowedOrigins: ["*"], AllowedHeaders: ["*"], MaxAge: 3600}
  PublicBucketPolicy:
    Type: AWS::S3::BucketPolicy
    Condition: Public
    Properties:
      Bucket: !Ref PublicBucket
      PolicyDocument:
        Statement:
          - Effect: Allow
            Principal: "*"
            Action: s3:GetObject
            Resource: !Sub ${PublicBucket.Arn}/*
          - Effect: Allow
            Principal: "*"
            Action: s3:ListBucket
            Resource: !GetAtt PublicBucket.Arn

  Repository:
    Type: AWS::ECR::Repository
    Properties:
      RepositoryName: orca
      ImageScanningConfiguration: {ScanOnPush: true}
      LifecyclePolicy:
        LifecyclePolicyText: |
          {"rules": [{"rulePriority": 1, "description": "keep the last 5",
            "selection": {"tagStatus": "any", "countType": "imageCountMoreThan", "countNumber": 5},
            "action": {"type": "expire"}}]}

  RunGroup:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: orca run instances, which talk to each other only
      VpcId: !Ref Vpc
  RunGroupSelf:
    Type: AWS::EC2::SecurityGroupIngress
    Properties:
      GroupId: !Ref RunGroup
      SourceSecurityGroupId: !Ref RunGroup
      IpProtocol: tcp
      FromPort: 0
      ToPort: 65535
  # The scheduler reads a scaling run's demand from its head (dista's port).
  RunGroupHead:
    Type: AWS::EC2::SecurityGroupIngress
    Properties:
      GroupId: !Ref RunGroup
      SourceSecurityGroupId: !Ref ControlGroup
      IpProtocol: tcp
      FromPort: 6390
      ToPort: 6390
  ControlGroup:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: orca control instance, public for HTTPS only
      VpcId: !Ref Vpc
      SecurityGroupIngress:
        - {IpProtocol: tcp, FromPort: 80, ToPort: 80, CidrIp: 0.0.0.0/0}
        - {IpProtocol: tcp, FromPort: 443, ToPort: 443, CidrIp: 0.0.0.0/0}
        - {IpProtocol: tcp, FromPort: 5432, ToPort: 5432, SourceSecurityGroupId: !Ref RunGroup}

  RunRole:
    Type: AWS::IAM::Role
    Properties:
      AssumeRolePolicyDocument:
        Statement: [{Effect: Allow, Principal: {Service: ec2.amazonaws.com}, Action: sts:AssumeRole}]
      ManagedPolicyArns: [arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore]
      Policies:
        # Runs' secrets (morca register --secret), only those under orca/.
        - PolicyName: secrets
          PolicyDocument:
            Statement:
              - Effect: Allow
                Action: secretsmanager:GetSecretValue
                Resource: !Sub arn:aws:secretsmanager:${AWS::Region}:${AWS::AccountId}:secret:orca/*
        - PolicyName: bucket-and-image
          PolicyDocument:
            Statement:
              - Effect: Allow
                Action: [s3:GetObject, s3:PutObject, s3:DeleteObject]
                Resource: [!Sub "${Bucket.Arn}/*", !Sub "${PublicBucket.Arn}/*"]
              # The control instance's backups (morca aws replace-control)
              # hold the database and Caddy's keys: no run reads them.
              - Effect: Deny
                Action: [s3:GetObject, s3:PutObject, s3:DeleteObject]
                Resource: !Sub "${Bucket.Arn}/backups/*"
              - Effect: Allow
                Action: s3:ListBucket
                Resource: [!GetAtt Bucket.Arn, !GetAtt PublicBucket.Arn]
              - Effect: Allow
                Action: [ecr:BatchGetImage, ecr:GetDownloadUrlForLayer]
                Resource: !GetAtt Repository.Arn
              - Effect: Allow
                Action: ecr:GetAuthorizationToken
                Resource: "*"
  RunProfile:
    Type: AWS::IAM::InstanceProfile
    Properties: {Roles: [!Ref RunRole]}

  ControlRole:
    Type: AWS::IAM::Role
    Properties:
      AssumeRolePolicyDocument:
        Statement: [{Effect: Allow, Principal: {Service: ec2.amazonaws.com}, Action: sts:AssumeRole}]
      ManagedPolicyArns: [arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore]
      Policies:
        # The secrets of runs placed on this instance (morca register
        # --placement control), which the scheduler reads as it starts them.
        - PolicyName: secrets
          PolicyDocument:
            Statement:
              - Effect: Allow
                Action: secretsmanager:GetSecretValue
                Resource: !Sub arn:aws:secretsmanager:${AWS::Region}:${AWS::AccountId}:secret:orca/*
        - PolicyName: run-instances
          PolicyDocument:
            Statement:
              # Only instances tagged for morca, of the allowed types, from
              # the stack's AMI, in its subnet and group, with its profile.
              - Effect: Allow
                Action: ec2:RunInstances
                Resource: !Sub arn:aws:ec2:${AWS::Region}:${AWS::AccountId}:instance/*
                Condition:
                  StringEquals: {ec2:InstanceType: !Ref AllowedRunTypes}
                  "Null": {"aws:RequestTag/orca.run": "false"}
              - Effect: Allow
                Action: ec2:RunInstances
                Resource:
                  - !Sub arn:aws:ec2:${AWS::Region}:${AWS::AccountId}:volume/*
                  - !Sub arn:aws:ec2:${AWS::Region}:${AWS::AccountId}:network-interface/*
                  - !Sub arn:aws:ec2:${AWS::Region}:${AWS::AccountId}:subnet/${Subnet}
                  - !Sub arn:aws:ec2:${AWS::Region}:${AWS::AccountId}:security-group/${RunGroup}
                  - !Sub arn:aws:ec2:${AWS::Region}::image/*
                  - !Sub arn:aws:ec2:${AWS::Region}:${AWS::AccountId}:spot-instances-request/*
              - Effect: Allow
                Action: ec2:CreateTags
                Resource: !Sub arn:aws:ec2:${AWS::Region}:${AWS::AccountId}:*/*
                Condition:
                  StringEquals: {ec2:CreateAction: RunInstances}
              - Effect: Allow
                Action: ec2:TerminateInstances
                Resource: !Sub arn:aws:ec2:${AWS::Region}:${AWS::AccountId}:instance/*
                Condition:
                  "Null": {"aws:ResourceTag/orca.run": "false"}
              # Its instances, and the boot script it runs (ControlBoot).
              - Effect: Allow
                Action: [ec2:DescribeInstances, ec2:DescribeLaunchTemplateVersions]
                Resource: "*"
              - Effect: Allow
                Action: iam:PassRole
                Resource: !GetAtt RunRole.Arn
        - PolicyName: bucket-and-image
          PolicyDocument:
            Statement:
              - Effect: Allow
                Action: [s3:GetObject, s3:PutObject, s3:DeleteObject]
                Resource: [!Sub "${Bucket.Arn}/*", !Sub "${PublicBucket.Arn}/*"]
              - Effect: Allow
                Action: s3:ListBucket
                Resource: [!GetAtt Bucket.Arn, !GetAtt PublicBucket.Arn]
              - Effect: Allow
                Action: [ecr:BatchGetImage, ecr:GetDownloadUrlForLayer]
                Resource: !GetAtt Repository.Arn
              - Effect: Allow
                Action: ecr:GetAuthorizationToken
                Resource: "*"
  ControlProfile:
    Type: AWS::IAM::InstanceProfile
    Properties: {Roles: [!Ref ControlRole]}

  ControlAddress:
    Type: AWS::EC2::EIP
    Properties: {Domain: vpc}
  # The control instance's boot script, kept as the user data of a launch
  # template that launches nothing: each control instance's own user data
  # runs the latest version of it, so changing it (or a parameter it uses)
  # stops no running instance. A new instance gets it: morca aws
  # replace-control, which boots one in the other slot.
  ControlBoot:
    Type: AWS::EC2::LaunchTemplate
    Properties:
      LaunchTemplateData:
        UserData:
          Fn::Base64: !Sub
            - |
              #!/bin/bash
              # orca-boot SLOT: morca's control instance, in slot blue or
              # green: Postgres, the scheduler, the UI and Caddy, as
              # containers that restart with the instance.
              set -eux
              slot=$1
              # Docker without ECS: this AMI's agent would look for a cluster.
              systemctl disable --now ecs || true
              systemctl enable --now docker
              command -v aws || dnf install -y awscli
              token=$(curl -sX PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 300')
              md() { curl -s -H "X-aws-ec2-metadata-token: $token" http://169.254.169.254/latest/meta-data/$1; }
              ip=$(md local-ipv4)
              # The Elastic IP's sslip.io name works at once; the hostname once
              # its A record points here. Caddy gets a certificate for each.
              sslip="$(echo ${PublicIp} | tr . -).sslip.io"
              hosts="$sslip"
              [ -z "${Hostname}" ] || hosts="${Hostname}, $sslip"
              registry=${AWS::AccountId}.dkr.ecr.${AWS::Region}.amazonaws.com
              image=$registry/orca:${ImageTag}
              login="command -v aws >/dev/null || dnf install -y awscli; systemctl disable --now ecs || true; aws ecr get-login-password --region ${AWS::Region} | docker login --username AWS --password-stdin $registry"
              # The image is pushed after the stack is made, so wait for it.
              until sh -c "$login" && docker pull $image; do sleep 30; done
              docker network create orca || true
              mkdir -p /var/lib/orca/pg /var/lib/orca/caddy /var/lib/orca/stage
              docker run -d --name postgres --restart always --network orca -p 5432:5432 \\
                -e POSTGRES_USER=orca -e POSTGRES_DB=orca -e POSTGRES_PASSWORD='${DbPassword}' \\
                -v /var/lib/orca/pg:/var/lib/postgresql/data postgres:17-bookworm -c synchronous_commit=on
              # Over TCP: the server that initialises the database listens on
              # its socket only, and restarts once it's done.
              until docker exec postgres pg_isready -h 127.0.0.1 -U orca -d orca; do sleep 2; done
              # A replacement (morca aws replace-control) points this slot at
              # the backup of the instance it replaces: its database, image
              # tag, Caddy's certificates and apps come back before anything
              # starts on them.
              backups=s3://${Bucket}/backups/${AWS::StackName}
              if aws s3 cp --region ${AWS::Region} $backups/restore-$slot /var/lib/orca/restore-from; then
                from=$(cat /var/lib/orca/restore-from)
                aws s3 cp --region ${AWS::Region} "$from.dump" /var/lib/orca/restore.dump
                docker exec -i postgres pg_restore -U orca -d orca --no-owner --exit-on-error < /var/lib/orca/restore.dump
                rm -f /var/lib/orca/restore.dump
                aws s3 cp --region ${AWS::Region} "$from.tag" /var/lib/orca/tag
                aws s3 cp --region ${AWS::Region} "$from.caddy.tgz" - | tar -xz -C /var/lib/orca/caddy
                aws s3 cp --region ${AWS::Region} "$from.apps" /var/lib/orca/apps
                echo "$from" > /var/lib/orca/restored
              fi
              [ -f /var/lib/orca/tag ] || echo ${ImageTag} > /var/lib/orca/tag
              cat > /etc/orca.env << EOF
              MORCA_DATABASE_URL=postgresql://orca:${DbPassword}@postgres:5432/orca
              MORCA_EC2_DATABASE_URL=postgresql://orca:${DbPassword}@$ip:5432/orca
              MORCA_RUNNER=ec2
              AWS_REGION=${AWS::Region}
              MORCA_EC2_AMI=${Ami}
              MORCA_EC2_SUBNET=${Subnet}
              MORCA_EC2_SECURITY_GROUP=${RunGroup}
              MORCA_EC2_PROFILE=${RunProfile}
              MORCA_EC2_PREAMBLE=$login
              MORCA_WAREHOUSE=s3://${PublicBucket}/warehouse
              MORCA_LOGS=s3://${Bucket}/logs
              MORCA_PUBLIC_WAREHOUSE=s3://${PublicBucket}/warehouse
              MORCA_RUN_ENV=MORCA_PUBLIC_WAREHOUSE
              MORCA_LOG_STAGE=/var/lib/orca/stage
              MORCA_CONTROL_SAMPLES=/var/lib/orca/stage/control.jsonl
              MORCA_CONTROL_TYPE=${ControlInstanceType}
              MORCA_UI_ADDR=0.0.0.0:8270
              MORCA_UI_LOGIN=required
              MORCA_UI_SECURE_COOKIES=1
              MORCA_UI_TRUST_PROXY=1
              EOF
              # The stack's own settings (ControlEnv; morca aws up --env K=V),
              # each in place of the line above with its key.
              printf '%s;' '${ControlEnv}' | tr ';' '\\n' | while IFS= read -r kv; do
                [ -n "$kv" ] || continue
                k=$(printf '%s' "$kv" | cut -d= -f1)
                grep -v "^$k=" /etc/orca.env > /etc/orca.env.new || true
                printf '%s\\n' "$kv" >> /etc/orca.env.new
                mv /etc/orca.env.new /etc/orca.env
              done
              chmod 600 /etc/orca.env
              # morca aws register and morca aws app run these over SSM.
              cat > /usr/local/bin/orca-refresh << 'EOS'
              #!/bin/bash
              # orca-refresh [TAG]: pull the morca image at TAG (else the last
              # one) and run the scheduler and the UI from it again.
              set -eu
              repo=${AWS::AccountId}.dkr.ecr.${AWS::Region}.amazonaws.com/orca
              [ $# -gt 0 ] && echo "$1" > /var/lib/orca/tag
              tag=$(cat /var/lib/orca/tag)
              aws ecr get-login-password --region ${AWS::Region} | docker login --username AWS --password-stdin "$(echo $repo | cut -d/ -f1)" > /dev/null
              docker pull -q "$repo:$tag"
              for role in scheduler ui; do
                docker rm -f $role > /dev/null 2>&1 || true
                docker run -d --name $role --restart always --network orca --env-file /etc/orca.env \\
                  -v /var/lib/orca/stage:/var/lib/orca/stage "$repo:$tag" $role
              done
              # This instance's own samples, for the fleet and system pages: the
              # host's processes and network, the last hour of lines kept in a
              # file the scheduler reads. The host's cgroup files and Docker's
              # container configs, read-only, give each container's memory by
              # name without the Docker socket.
              docker rm -f sampler > /dev/null 2>&1 || true
              docker run -d --name sampler --restart always --pid host --network host \\
                -v /var/lib/orca/stage:/var/lib/orca/stage \\
                -v /sys/fs/cgroup:/host/cgroup:ro -v /var/lib/docker/containers:/host/containers:ro "$repo:$tag" \\
                sample --out /var/lib/orca/stage/control.jsonl --dirs /var/lib/orca/stage --keep 720 \\
                --cgroup /host/cgroup --names /host/containers
              EOS
              cat > /usr/local/bin/orca-app << 'EOS'
              #!/bin/bash
              # orca-app NAME HOST [PORT]: run the image's /opt/morca/bin/NAME as
              # an app beside the UI, at https://HOST through Caddy, with the
              # region, the warehouse and PORT (default 8080). It's recorded in
              # /var/lib/orca/apps, which a replacement instance runs again.
              set -eu
              name=$1
              host=$2
              port=8080
              [ $# -gt 2 ] && port=$3
              repo=${AWS::AccountId}.dkr.ecr.${AWS::Region}.amazonaws.com/orca
              tag=$(cat /var/lib/orca/tag)
              aws ecr get-login-password --region ${AWS::Region} | docker login --username AWS --password-stdin "$(echo $repo | cut -d/ -f1)" > /dev/null
              docker pull -q "$repo:$tag"
              docker rm -f "$name" > /dev/null 2>&1 || true
              # An app reads the lake, not morca's database: it gets no password.
              grep -E '^(AWS_REGION|MORCA_WAREHOUSE|MORCA_PUBLIC_WAREHOUSE)=' /etc/orca.env > /var/lib/orca/app.env
              docker run -d --name "$name" --restart always --network orca --env-file /var/lib/orca/app.env \\
                -e PORT=$port --entrypoint /opt/morca/bin/$name "$repo:$tag"
              { grep -v "^$name " /var/lib/orca/apps 2> /dev/null || true; echo "$name $host $port"; } > /var/lib/orca/apps.new
              mv /var/lib/orca/apps.new /var/lib/orca/apps
              grep -q "^$host {" /var/lib/orca/Caddyfile \\
                || printf '%s {\\n  encode zstd gzip\\n  reverse_proxy %s:%s\\n}\\n' "$host" "$name" "$port" >> /var/lib/orca/Caddyfile
              # Caddy may still be starting.
              for _ in $(seq 30); do
                docker exec caddy caddy reload --config /etc/caddy/Caddyfile && exit 0
                sleep 2
              done
              exit 1
              EOS
              chmod +x /usr/local/bin/orca-refresh /usr/local/bin/orca-app
              orca-refresh
              cat > /var/lib/orca/Caddyfile << EOF
              $hosts {
                encode zstd gzip
                reverse_proxy ui:8270
              }
              EOF
              # The console, once a container named console runs on the network.
              [ -z "${ConsoleHostname}" ] || printf '%s {\\n  encode zstd gzip\\n  reverse_proxy console:8080\\n}\\n' "${ConsoleHostname}" >> /var/lib/orca/Caddyfile
              docker run -d --name caddy --restart always --network orca -p 80:80 -p 443:443 \\
                -v /var/lib/orca/Caddyfile:/etc/caddy/Caddyfile -v /var/lib/orca/caddy:/data caddy:2.10
              # The apps the replaced instance ran.
              if [ -f /var/lib/orca/apps ]; then
                cp /var/lib/orca/apps /var/lib/orca/apps.boot
                while read -r name host port; do orca-app "$name" "$host" "$port"; done < /var/lib/orca/apps.boot
              fi
              echo "morca ui at https://$sslip and https://${Hostname}"
              date -u +%FT%TZ > /var/lib/orca/booted
            - {PublicIp: !Ref ControlAddress}
  # Two slots for the control instance, blue (Control, the stack's first)
  # and green; the Elastic IP is on the active one. morca aws
  # replace-control turns the other slot on with a fresh instance, moves
  # ActiveControl to it once it's healthy, and turns the old slot off at the
  # end of the rollback window. Each slot's AMI is pinned (BlueAmi,
  # GreenAmi): the Ami parameter resolves again on every update, and a new
  # image id would replace the running instance, its database with it.
  Control:
    Type: AWS::EC2::Instance
    Condition: BlueOn
    DependsOn: DefaultRoute
    Properties:
      ImageId: !If [BlueAmiPinned, !Ref BlueAmi, !Ref Ami]
      InstanceType: !Ref ControlInstanceType
      SubnetId: !Ref Subnet
      SecurityGroupIds: [!Ref ControlGroup]
      IamInstanceProfile: !Ref ControlProfile
      MetadataOptions: {HttpTokens: required, HttpPutResponseHopLimit: 2}
      BlockDeviceMappings:
        - DeviceName: /dev/xvda
          Ebs: {VolumeSize: 40, VolumeType: gp3, Encrypted: true}
      Tags: [{Key: Name, Value: orca-control}, {Key: orca.slot, Value: blue}]
      UserData:
        Fn::Base64: !Sub |
          #!/bin/bash
          # morca's control instance, slot blue: the latest version of the
          # stack's boot script (ControlBoot).
          set -eux
          command -v aws || dnf install -y awscli
          until aws ec2 describe-launch-template-versions --region ${AWS::Region} --launch-template-id ${ControlBoot} \\
              --versions '$Latest' --query 'LaunchTemplateVersions[0].LaunchTemplateData.UserData' --output text > /root/orca-boot.b64; do sleep 10; done
          base64 -d /root/orca-boot.b64 > /usr/local/bin/orca-boot
          chmod 700 /usr/local/bin/orca-boot
          exec /usr/local/bin/orca-boot blue
  ControlGreen:
    Type: AWS::EC2::Instance
    Condition: GreenOn
    DependsOn: DefaultRoute
    Properties:
      ImageId: !If [GreenAmiPinned, !Ref GreenAmi, !Ref Ami]
      InstanceType: !Ref ControlInstanceType
      SubnetId: !Ref Subnet
      SecurityGroupIds: [!Ref ControlGroup]
      IamInstanceProfile: !Ref ControlProfile
      MetadataOptions: {HttpTokens: required, HttpPutResponseHopLimit: 2}
      BlockDeviceMappings:
        - DeviceName: /dev/xvda
          Ebs: {VolumeSize: 40, VolumeType: gp3, Encrypted: true}
      Tags: [{Key: Name, Value: orca-control}, {Key: orca.slot, Value: green}]
      UserData:
        Fn::Base64: !Sub |
          #!/bin/bash
          # morca's control instance, slot green: the latest version of the
          # stack's boot script (ControlBoot).
          set -eux
          command -v aws || dnf install -y awscli
          until aws ec2 describe-launch-template-versions --region ${AWS::Region} --launch-template-id ${ControlBoot} \\
              --versions '$Latest' --query 'LaunchTemplateVersions[0].LaunchTemplateData.UserData' --output text > /root/orca-boot.b64; do sleep 10; done
          base64 -d /root/orca-boot.b64 > /usr/local/bin/orca-boot
          chmod 700 /usr/local/bin/orca-boot
          exec /usr/local/bin/orca-boot green
  # Its own resource, so moving the address is a change to it alone.
  ControlAddressAssociation:
    Type: AWS::EC2::EIPAssociation
    Properties:
      InstanceId: !If [GreenActive, !Ref ControlGreen, !Ref Control]
      AllocationId: !GetAtt ControlAddress.AllocationId

  Budget:
    Type: AWS::Budgets::Budget
    Properties:
      Budget:
        BudgetName: orca
        BudgetType: COST
        TimeUnit: MONTHLY
        BudgetLimit: {Amount: !Ref BudgetDollars, Unit: USD}
      NotificationsWithSubscribers:
        - Notification: {NotificationType: ACTUAL, ComparisonOperator: GREATER_THAN, Threshold: 80}
          Subscribers: [{SubscriptionType: EMAIL, Address: !Ref BudgetEmail}]
        - Notification: {NotificationType: FORECASTED, ComparisonOperator: GREATER_THAN, Threshold: 100}
          Subscribers: [{SubscriptionType: EMAIL, Address: !Ref BudgetEmail}]

Outputs:
  SslipUrl:
    Value: !Sub
      - https://${Dashed}.sslip.io
      - Dashed: !Join ["-", !Split [".", !Ref ControlAddress]]
  Repository:
    Value: !Sub ${AWS::AccountId}.dkr.ecr.${AWS::Region}.amazonaws.com/orca
  Bucket:
    Value: !Ref Bucket
  PublicBucket:
    Description: The lake's bucket; with PublicData, read it unsigned, e.g. aws s3 ls --no-sign-request s3://<it>/
    Value: !Ref PublicBucket
  ControlInstance:
    Description: The active control instance, which has the Elastic IP
    Value: !If [GreenActive, !Ref ControlGreen, !Ref Control]
  ActiveControl:
    Value: !Ref ActiveControl
  BlueInstance:
    Condition: BlueOn
    Value: !Ref Control
  GreenInstance:
    Condition: GreenOn
    Value: !Ref ControlGreen
  AddressAllocation:
    Value: !GetAtt ControlAddress.AllocationId
  ConsoleHostname:
    Value: !Ref ConsoleHostname
  PublicAddress:
    Value: !Ref ControlAddress
"""

comptime PROJECT_DOCKERFILE: StaticString = """# The image `morca aws push` builds for a project that added morca with
# `pixi shelf add morca-mojo`, on morca's runtime image,
# ghcr.io/morca-dev/morca-runtime:<MORCA_VERSION> (deploy/runtime.Dockerfile).
# The runtime has morca's own `morca` and `morca_maintain`, git, libcurl, the CA
# bundles, llvm-symbolizer and the /opt/morca layout and environment; this
# adds only the project's programs:
#
# - its apps, every bin/*.mojo, at /opt/morca/bin/<name> (`morca aws app` runs
#   them). bin/scheduler.mojo, the two lines calling morca.command, becomes
#   /opt/morca/bin/morca in place of the runtime's, and bin/morca_maintain.mojo
#   /opt/morca/bin/morca_maintain; a project without them runs the runtime's.
# - its pipelines, every pipelines/*.mojo, at /opt/morca/pipelines/<name>,
#   with the source map `morca locate` writes beside each.
# - its morca.toml, if it has one, at /opt/morca/morca.toml, which
#   MORCA_CONFIG names: a bare `morca register` (morca-stack register) reads
#   it. A project without one has nothing there, and registers with
#   --no-config or a --config of its own.
# - its upgrade.toml, if it has one, at /opt/morca/upgrade.toml, which
#   MORCA_UPGRADE names: the steps a deploy of each release needs, which
#   deploy/hetzner's deploy.sh reads (`morca upgrade`,
#   docs/hetzner.md#a-releases-upgrade-steps). Without one a deploy has none.
# - its CHANGELOG.md, if it has one, at /opt/morca/CHANGELOG.md.
# - the pixi environment's libraries those link or dlopen, in /opt/morca/lib
#   over the runtime's, so the project's own versions win.
#
# `src/` is on the import path if the project has one. A project with a
# Dockerfile.morca of its own builds that instead, and can start it the same
# way: `ARG MORCA_VERSION` and `FROM ghcr.io/morca-dev/morca-runtime:${MORCA_VERSION}`.
#
# MORCA_VERSION is the morca-mojo the project pins, which `morca aws push`
# reads from pixi.lock; the runtime and the project's pipelines are then the
# same morca. By hand:
#
#     docker build -f project.Dockerfile --build-arg MORCA_VERSION=0.24.0 \\
#         -t ghcr.io/<owner>/<project>:<version> .
#
# Name the image after the project (ghcr.io/morca-dev/census, not
# ghcr.io/morca-dev/morca), and set MORCA_IMAGE in deploy/hetzner's
# hetzner.env to it. MORCA_RUNTIME names another runtime repository, such as
# one built locally (`docker build -f deploy/runtime.Dockerfile -t
# morca-runtime:0.24.0 .` in morca, then --build-arg MORCA_RUNTIME=morca-runtime).
#
# MORCA_SOURCE and MORCA_COMMIT say what the pipelines were built from, which
# each run records and morca ui links. They're set in the image's environment,
# not compiled in.
#
# Everything is built with line tables (-g1) and the image has
# llvm-symbolizer, so a crash's stack dump in a run's driver.log names each
# frame's function, file and line (morca.crash). The line tables, compressed,
# make a binary about half as big again (mojo-census's gharchive: 4.2 MB,
# 6.5 MB with them, 25 MB uncompressed) and leave its speed as it was.
#
# The binaries are built for MOJO_TARGET_CPU, not for the CPU of the machine
# building them (`mojo build` defaults to that). GitHub's arm64 runners are
# Neoverse N2, which has SVE2; Hetzner's CAX servers are Neoverse N1, which
# has not, so a binary built there dies on the server with SIGILL (exit
# 132). N1 code runs on N2, V1, V2 and Graviton. Build for something else
# with --build-arg MOJO_TARGET_CPU=<cpu> (x86-64-v3 for linux/amd64).
# No default version: the error for a build without one names what's missing.
ARG MORCA_VERSION=needs-build-arg-morca-version
ARG MORCA_RUNTIME=ghcr.io/morca-dev/morca-runtime
FROM ${MORCA_RUNTIME}:${MORCA_VERSION} AS runtime

FROM ghcr.io/prefix-dev/pixi:0.78.0-bookworm AS build
RUN apt-get update && apt-get install -y --no-install-recommends gcc libc6-dev git ca-certificates \\
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src/project
COPY pixi.toml pixi.lock ./
RUN pixi install --locked
# The runtime's morca, for `morca locate` when the project has no bin/scheduler.mojo.
COPY --from=runtime /opt/morca /opt/morca-runtime
ARG MOJO_TARGET_CPU=neoverse-n1
COPY . .
RUN mkdir -p /out/bin /out/pipelines /out/config \\
    && for c in morca.toml upgrade.toml CHANGELOG.md; do [ ! -f "$c" ] || cp "$c" "/out/config/$c" || exit 1; done \\
    && pixi run sh -c 'inc=""; [ -d src ] && inc="-I src"; \\
        for f in bin/*.mojo; do [ -f "$f" ] || continue; n=$(basename "$f" .mojo); [ "$n" = scheduler ] && n=morca; \\
            mojo build -g1 --target-cpu "$MOJO_TARGET_CPU" $inc "$f" -o "/out/bin/$n" || exit 1; done; \\
        for p in pipelines/*.mojo; do [ -f "$p" ] || continue; n=$(basename "$p" .mojo); \\
            mojo build -g1 --target-cpu "$MOJO_TARGET_CPU" $inc \\
                "$p" -o "/out/pipelines/$n" || exit 1; done; \\
        morca=/out/bin/morca; [ -x "$morca" ] || morca=/opt/morca-runtime/bin/morca; \\
        if ls /out/pipelines/* > /dev/null 2>&1; then \\
            LD_LIBRARY_PATH="$CONDA_PREFIX/lib:/opt/morca-runtime/lib" "$morca" locate /out/pipelines/* --root .; fi'
# The line tables compressed, which llvm-symbolizer reads as they are.
RUN for b in /out/bin/* /out/pipelines/*; do [ -x "$b" ] || continue; \\
        objcopy --compress-debug-sections=zlib "$b" || exit 1; done
# Only the pixi environment's libraries the binaries link or dlopen: libpq
# (postgres), flare's shims (morca ui, apps), and every tin's shim, such as
# objectstore's and the codecs' (zstd, for Iceberg writes). Not conda's
# libpsl and ICU, which only libcurl links: the runtime has Debian's libpsl5.
RUN env=/src/project/.pixi/envs/default && mkdir -p /out/lib \\
    && loaded=$(ls $env/lib/libpq.so* $env/lib/libflare_*.so $env/lib/lib*mojo*.so 2>/dev/null) \\
    && ldd /out/bin/* /out/pipelines/* $loaded 2> /dev/null | awk -v e="$env" '$3 ~ "^"e {print $3}' \\
        | grep -v -e '/libicu' -e '/libpsl' | sort -u | xargs -r cp -L -t /out/lib \\
    && cp -L -t /out/lib $loaded

FROM runtime
COPY --from=build /out/lib /opt/morca/lib
COPY --from=build /out/bin /opt/morca/bin
COPY --from=build /out/pipelines /opt/morca/pipelines
COPY --from=build /out/config/ /opt/morca/
ENV MORCA_CONFIG=/opt/morca/morca.toml MORCA_UPGRADE=/opt/morca/upgrade.toml
# What the pipelines were built from, read at run time (morca.source), not
# compiled in: a new commit then changes no program, and the build above
# stays cacheable. Declared last, so a new commit reruns only this layer.
ARG MORCA_SOURCE=""
ARG MORCA_COMMIT=""
ENV MORCA_SOURCE=${MORCA_SOURCE} MORCA_COMMIT=${MORCA_COMMIT}
"""
