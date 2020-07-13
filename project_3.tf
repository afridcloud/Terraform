### provider definition for AWS

provider "aws" {
  region = "ap-south-1"
}




### To create a key with public key in the console and the private key in the local machine

resource "tls_private_key" "mykey" {
  algorithm = "RSA"
  rsa_bits = 4096
}

resource "aws_key_pair" "generated_key" {
  key_name   = "mykey"
  public_key = "${tls_private_key.mykey.public_key_openssh}"
  
  depends_on = [ tls_private_key.mykey ]
}

resource "local_file" "key-file" {
  content  = "${tls_private_key.mykey.private_key_pem}"
  filename = "mykey.pem"
  file_permission = 0400

  depends_on = [
    tls_private_key.mykey
  ]
}




## To create a custom VPC

resource "aws_vpc" "main" {
  cidr_block       = "10.0.0.0/16"
  instance_tenancy = "default"
  enable_dns_hostnames = "true"

  tags = {
    Name = "custom_vpc"
  }
}




### creating the security group fop allowing 80,22 inbound rules

resource "aws_security_group" "wp_sec_grp" {
  name        = "wp_sec_grp"
  description = "Allows SSH and HTTP"
  vpc_id      = "${aws_vpc.main.id}"

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [ "0.0.0.0/0" ]
  }
 
  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [ "0.0.0.0/0" ]
  }

  ingress {
    description = "allow ICMP"
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "wp_sec_grp"
  }
}




### creating the security group fop allowing 3306 inbound rules

resource "aws_security_group" "mysql_sec_group" {
  name        = "mysql_sec_grp"
  description = "Allows MYSQL"
  vpc_id      = "${aws_vpc.main.id}"

  tags = {
    Name = "mysql_sec_group"
  }
}

resource "aws_security_group_rule" "allow_mysql_from_wp" {
  type              = "ingress"
  from_port         = 0
  to_port           = 3306
  protocol          = "tcp"
  security_group_id = "${aws_security_group.mysql_sec_group.id}"
  source_security_group_id = "${aws_security_group.wp_sec_grp.id}"
}



## To create one subnet for private and public

resource "aws_subnet" "public" {
  vpc_id     = aws_vpc.main.id
  cidr_block = "10.0.1.0/24"
  availability_zone = "ap-south-1a"

  tags = {
    Name = "public_subnet1"
  }
}

resource "aws_subnet" "private" {
    vpc_id = aws_vpc.main.id
    cidr_block = "10.0.2.0/24"
    availability_zone = "ap-south-1b"

    tags = {
      Name = "private_subnet2"
    }
}




## To create one IGW in cutom created VPC

resource "aws_internet_gateway" "custom_igww" {
  vpc_id = "${aws_vpc.main.id}"

  tags = {
    Name = "custom_igw"
  }
}




## To create the route table to have public access

resource "aws_route_table" "route" {
  vpc_id = "${aws_vpc.main.id}"
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = "${aws_internet_gateway.custom_igww.id}"
  }

  tags = {
    Name = "route_to_world"
  }
}




## To associate the route table with the subnet created for public access

resource "aws_route_table_association" "a" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.route.id
}




## Create a instance with wordpress for public access

resource "aws_instance" "wordpress" {
    ami           = "ami-7e257211"
    instance_type = "t2.micro"
    associate_public_ip_address = true
    subnet_id = "${aws_subnet.public.id}"
    vpc_security_group_ids = [aws_security_group.wp_sec_grp.id]
    key_name = "${aws_key_pair.generated_key.key_name}"

    tags = {
        Name = "wordpress_os"
    }

    depends_on = [ tls_private_key.mykey, aws_vpc.main, aws_security_group.wp_sec_grp, aws_security_group.mysql_sec_group, aws_subnet.public, aws_subnet.private, aws_internet_gateway.custom_igww ] 

}
  


## Create a instance with wordpress for private access but only allowed by wordpress in the private network & not for any

resource "aws_instance" "mysql" {
	ami = "ami-08706cb5f68222d09"
	instance_type = "t2.micro"
	key_name = "${aws_key_pair.generated_key.key_name}"
    vpc_security_group_ids = [aws_security_group.mysql_sec_group.id]
    subnet_id = "${aws_subnet.private.id}"

    tags = {
        Name = "mysql_os"
    }

    depends_on = [ tls_private_key.mykey, aws_vpc.main, aws_security_group.wp_sec_grp, aws_security_group.mysql_sec_group, aws_subnet.public, aws_subnet.private, aws_internet_gateway.custom_igww ] 
}


# Take output of Wordpress and MySQL DB instances:



output "wordpress-publicip" {
  value = aws_instance.wordpress.public_ip
}



output "mysqldb-privateip" {
  value = aws_instance.mysql.private_ip
}
