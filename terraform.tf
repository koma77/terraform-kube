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

## kube-api from the VPC
  ingress {
    from_port   = 6443
    to_port     = 6443
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

resource "aws_security_group" "kube_api_elb" {
  name        = "kube_api_sec_group_elb"
  description = "Managed by terraform"
  vpc_id      = "${aws_vpc.kube_vpc.id}"

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

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


resource "aws_elb" "kube_api" {
  name = "kube-api-elb"

  subnets         = ["${aws_subnet.kube_subnet.id}"]
  security_groups = ["${aws_security_group.kube_api_elb.id}"]
  instances       = ["${aws_instance.kube.id}"]

  listener {
    instance_port     = 6443
    instance_protocol = "tcp"
    lb_port           = 443
    lb_protocol       = "tcp"
  }

  health_check {
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 2
    target              = "TCP:6443"
    interval            = 5
  }

}

resource "aws_instance" "kube" {
  connection {
    user = "core"
    private_key = "${file("~/.ssh/terraform")}"
  }

  instance_type = "t2.micro"
  iam_instance_profile = "${aws_iam_instance_profile.kube_controller.id}"

  ami = "ami-602f5403"

  key_name = "${aws_key_pair.auth.id}"

  vpc_security_group_ids = ["${aws_security_group.kube_sec_group.id}"]
  subnet_id = "${aws_subnet.kube_subnet.id}"

  root_block_device {
    volume_size = "8"
    delete_on_termination = "true"
  }

}

### Need this to break dependancy cycle between elb and instance
resource "null_resource" "ansible-provisioner" {
  provisioner "local-exec" {
    command = "sleep 10; ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook -u core  --private-key ~/.ssh/terraform -i ${aws_instance.kube.public_ip}, -e kube_api_addr=${aws_instance.kube.private_ip} -e kube_api_elb=${aws_elb.kube_api.dns_name} ansible/kube.yml"
  }
}

output "kube_vm_ip" {
  value = "${aws_instance.kube.public_ip}"
}


output "kube-api" {
  value = "${aws_elb.kube_api.dns_name}"  
}
