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

  ingress {
    description = "allow ICMP"
    from_port = 0
    to_port = 0
    protocol = "-1"
    security_groups = [aws_security_group.wp_sec_grp.id]
  }

  ingress {
    description = "allow MySQL"
    from_port = 0
    to_port = 3306
    protocol = "tcp"
    security_groups = [aws_security_group.wp_sec_grp.id]
  }


  egress {
  description = "allow ICMP"
  from_port = 0
  to_port=0
  protocol = "-1"
  cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "mysql_sec_group"
  }
}




## To create one subnet for private and public

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_subnet" "public" {
  vpc_id     = aws_vpc.main.id
  cidr_block = "10.0.1.0/24"
  availability_zone = data.aws_availability_zones.available.names[0]

  tags = {
    Name = "public_subnet"
  }
}

resource "aws_subnet" "private" {
    vpc_id = aws_vpc.main.id
    cidr_block = "10.0.2.0/24"
    availability_zone = data.aws_availability_zones.available.names[1]

    tags = {
      Name = "private_subnet"
    }
}




## To create one IGW in cutom created VPC

resource "aws_internet_gateway" "custom_igww" {
  vpc_id = "${aws_vpc.main.id}"

  tags = {
    Name = "custom_igw"
  }
}


## creating the EIP for NAT Gateway


resource "aws_eip" "nat-eip" {
	vpc = true

	depends_on = [ aws_internet_gateway.custom_igww ]
}


## Creating the NAT Gateway

resource "aws_nat_gateway" "natgw" {
	allocation_id = "${aws_eip.nat-eip.id}"
	subnet_id = "${aws_subnet.public.id}"

	depends_on = [ aws_internet_gateway.custom_igww ]

	tags = {
		Name = "my-natgw"
	}
}






## To create the route table to have public instance to go to public world via IGW

resource "aws_route_table" "public_route" {
  vpc_id = "${aws_vpc.main.id}"
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = "${aws_internet_gateway.custom_igww.id}"
  }

  tags = {
    Name = "public_route"
  }
}



## To create the route table for private instance to go to public world via NAT


resource "aws_route_table" "private_route" {
	vpc_id = "${aws_vpc.main.id}"

	route {
		cidr_block = "0.0.0.0/0"
		nat_gateway_id = "${aws_nat_gateway.natgw.id}"
	}

	tags = {
		Name = "private_route"
	}
}


## To associate the route table with the subnet created for public access

resource "aws_route_table_association" "public_sn_assoc" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public_route.id
}



## To associate the route table with the private subnet for public access


resource "aws_route_table_association" "private_sn_assoc" {
	subnet_id = aws_subnet.private.id
	route_table_id = aws_route_table.private_route.id
}




### to ask for ami name to launch if not use default


variable "ami_name_wp" {
  type = "string"
  default = "ami-7e257211"
}

variable "ami_name_mysql" {
  type = "string"
  default = "ami-08706cb5f68222d09"
}





## Create a instance with wordpress for public access

resource "aws_instance" "wordpress" {
    ami           = "${var.ami_name_wp}"
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
	ami = "${var.ami_name_mysql}"
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


