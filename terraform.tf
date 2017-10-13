#

provider "aws" {
  region     = "ap-southeast-1"
}

resource "aws_vpc" "kube_vpc" {
  cidr_block = "10.0.0.0/16"
}

resource "aws_internet_gateway" "kube_gw" {
  vpc_id = "${aws_vpc.kube_vpc.id}"
}

resource "aws_route" "internet_access" {
  route_table_id         = "${aws_vpc.kube_vpc.main_route_table_id}"
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = "${aws_internet_gateway.kube_gw.id}"
}

resource "aws_subnet" "kube_subnet" {
  vpc_id                  = "${aws_vpc.kube_vpc.id}"
  cidr_block              = "10.0.10.0/24"
  availability_zone       = "ap-southeast-1a"
  map_public_ip_on_launch = true
}

resource "aws_iam_role" "kube_controller" {
    name = "kube_controller"
    description = "Managed by terrafrom"
    assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF
}

resource "aws_iam_role_policy" "kube_allow_elb_management" {
    name        = "kube_allow_elb_policy"
    role = "${aws_iam_role.kube_controller.id}"
    policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
        "Effect": "Allow",
        "Action": [
          "ec2:Describe*",
          "ec2:CreateSecurityGroup",
          "ec2:DescribeSecurityGroups",
          "ec2:AuthorizeSecurityGroupIngress",
          "ec2:AuthorizeSecurityGroupEgress",
          "ec2:DeleteSecurityGroup",
          "ec2:RevokeSecurityGroupEgress",
          "ec2:RevokeSecurityGroupIngress",
          "elasticloadbalancing:*"
        ],
        "Resource": [ "*" ]
    }
  ]
}
EOF
}


resource "aws_iam_instance_profile" "kube_controller" {
  name  = "kube_controller"
  role = "${aws_iam_role.kube_controller.name}"
}

#resource "aws_security_group" "elb" {
#  name        = "test_sec_group_elb"
#  description = "! Managed by terraform"
#  vpc_id      = "${aws_vpc.test_vpc.id}"
#
#  ingress {
#    from_port   = 80
#    to_port     = 80
#    protocol    = "tcp"
#    cidr_blocks = ["0.0.0.0/0"]
#  }
#
#  egress {
#    from_port   = 0
#    to_port     = 0
#    protocol    = "-1"
#    cidr_blocks = ["0.0.0.0/0"]
#  }
#}


resource "aws_security_group" "kube_sec_group" {
  name        = "kube_sec_group"
  description = "Managed by terraform"
  vpc_id      = "${aws_vpc.kube_vpc.id}"

  # SSH access from anywhere
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ## HTTP access from the VPC
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["10.0.10.0/24"]
  }

  # outbound internet access
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}


resource "aws_key_pair" "auth" {
  key_name   = "terraform"
  public_key = "${file("~/.ssh/terraform.pub")}"
}

resource "aws_instance" "kube" {
  connection {
    user = "centos"
    private_key = "${file("~/.ssh/terraform")}"
  }

  instance_type = "t2.micro"
  iam_instance_profile = "${aws_iam_instance_profile.kube_controller.id}"
  iam_instance_profile = "${aws_iam_instance_profile.kube_controller.id}"

  ami = "ami-1fbad07c"

  key_name = "${aws_key_pair.auth.id}"

  vpc_security_group_ids = ["${aws_security_group.kube_sec_group.id}"]

  subnet_id = "${aws_subnet.kube_subnet.id}"

  root_block_device {
    volume_size = "8"
    delete_on_termination = "true"
  }

  provisioner "remote-exec" {
    inline = [
      "sudo yum -y install epel-release",
      "sudo yum -y update",
      "sudo shutdown -r"
    ]
  }

  provisioner "local-exec" {
    command = "ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook -u centos  --private-key ~/.ssh/terraform -i '${aws_instance.kube.public_ip},' ansible/kube.yml"
  }

}

output "kube_vm_ip" {
    value = "${aws_instance.kube.public_ip}"
}
