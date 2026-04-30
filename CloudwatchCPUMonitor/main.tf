terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

provider "aws" {
  region = var.region
}

data "aws_availability_zones" "available" {
  state = "available"
}

module "vpc" {
  source = "terraform-aws-modules/vpc/aws"

  name = "monitoring-vpc"
  cidr = "10.0.0.0/16"

  azs            = [data.aws_availability_zones.available.names[0]]
  public_subnets = ["10.0.1.0/24"]

  map_public_ip_on_launch = true

  tags = {
    Terraform   = "true"
    Environment = "development"
    Project     = "cloudwatch-monitoring"
  }
}

resource "aws_iam_role" "ec2_role" {
  name = "ec2-ssm-cloudwatch-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "cloudwatch_agent" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "ec2-monitoring-profile"
  role = aws_iam_role.ec2_role.name
}

data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

module "ec2_instance" {
  source = "terraform-aws-modules/ec2-instance/aws"

  name = "monitoring-instance"

  ami           = data.aws_ami.amazon_linux.id
  instance_type = "t3.micro"

  subnet_id                   = module.vpc.public_subnets[0]
  associate_public_ip_address = true

  iam_instance_profile = aws_iam_instance_profile.ec2_profile.name

  user_data = <<-EOF
#!/bin/bash
set -e

systemctl enable amazon-ssm-agent
systemctl restart amazon-ssm-agent

dnf install -y amazon-cloudwatch-agent stress

cat <<EOT > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json
{
  "metrics": {
    "metrics_collected": {
      "mem": {
        "measurement": ["mem_used_percent"]
      },
      "disk": {
        "measurement": ["used_percent"],
        "resources": ["/"]
      }
    }
  }
}
EOT

/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
-a fetch-config \
-m ec2 \
-c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json \
-s
EOF

  tags = {
    Terraform   = "true"
    Environment = "development"
    Project     = "cloudwatch-monitoring"
  }
}

resource "aws_sns_topic" "alerts" {
  name = "monitoring-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_cloudwatch_metric_alarm" "cpu" {
  alarm_name          = "high-cpu"
  alarm_description   = "CPU usage is above 70 percent."
  comparison_operator = "GreaterThanThreshold"
  threshold           = 70
  evaluation_periods  = 1
  period              = 300
  statistic           = "Average"

  namespace   = "AWS/EC2"
  metric_name = "CPUUtilization"

  dimensions = {
    InstanceId = module.ec2_instance.id
  }

  alarm_actions      = [aws_sns_topic.alerts.arn]
  ok_actions         = [aws_sns_topic.alerts.arn]
  treat_missing_data = "notBreaching"
}

resource "aws_cloudwatch_metric_alarm" "memory" {
  alarm_name          = "high-memory"
  alarm_description   = "Memory usage is above 80 percent."
  comparison_operator = "GreaterThanThreshold"
  threshold           = 80
  evaluation_periods  = 1
  period              = 300
  statistic           = "Average"

  namespace   = "CWAgent"
  metric_name = "mem_used_percent"

  dimensions = {
    InstanceId = module.ec2_instance.id
  }

  alarm_actions      = [aws_sns_topic.alerts.arn]
  ok_actions         = [aws_sns_topic.alerts.arn]
  treat_missing_data = "notBreaching"
}

resource "aws_cloudwatch_metric_alarm" "disk" {
  alarm_name          = "high-disk"
  alarm_description   = "Disk usage is above 80 percent."
  comparison_operator = "GreaterThanThreshold"
  threshold           = 80
  evaluation_periods  = 1
  period              = 300
  statistic           = "Average"

  namespace   = "CWAgent"
  metric_name = "disk_used_percent"

  dimensions = {
    InstanceId = module.ec2_instance.id
    path       = "/"
    fstype     = "xfs"
  }

  alarm_actions      = [aws_sns_topic.alerts.arn]
  ok_actions         = [aws_sns_topic.alerts.arn]
  treat_missing_data = "notBreaching"
}

output "instance_id" {
  value = module.ec2_instance.id
}

output "public_ip" {
  value = module.ec2_instance.public_ip
}

output "sns_topic_arn" {
  value = aws_sns_topic.alerts.arn
}