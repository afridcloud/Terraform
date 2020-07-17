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

resource "aws_vpc" "custom_vpc" {
  cidr_block       = "10.0.0.0/16"
  instance_tenancy = "default"
  enable_dns_support   = "true"
  enable_dns_hostnames = "true"

  tags = {
    Name = "custom_vpc"
  }
}


## To create one subnet for private and public

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_subnet" "public" {
  vpc_id     = aws_vpc.custom_vpc.id
  cidr_block = "10.0.1.0/24"
  map_public_ip_on_launch = "true"
  availability_zone = data.aws_availability_zones.available.names[0]

  tags = {
    Name = "public_subnet"
  }
}




## To create one IGW in cutom created VPC

resource "aws_internet_gateway" "custom_igww" {
  vpc_id = "${aws_vpc.custom_vpc.id}"

  tags = {
    Name = "custom_igw"
  }
}




## To create the route table to have public instance to go to public world via IGW

resource "aws_route_table" "public_route" {
  vpc_id = "${aws_vpc.custom_vpc.id}"
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = "${aws_internet_gateway.custom_igww.id}"
  }

  tags = {
    Name = "public_route"
  }
}



## To associate the route table with the subnet created for public access

resource "aws_route_table_association" "public_sn_assoc" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public_route.id
}




### creating the security group fop allowing 80,22 inbound rules

resource "aws_security_group" "sec_grp_web" {
  name        = "wp_sec_grp"
  description = "Allows SSH and HTTP"
  vpc_id      = "${aws_vpc.custom_vpc.id}"

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
    description = "HTTP"
    from_port   = 2049
    to_port     = 2049
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


### to ask for ami name to launch if not use default


variable "ami_name" {
  type = "string"
  default = "ami-0732b62d310b80e97"
}

## Create a instance with wordpress for public access

resource "aws_instance" "web" {
    ami           = "${var.ami_name}"
    instance_type = "t2.micro"
    associate_public_ip_address = true
    availability_zone = "${data.aws_availability_zones.available.names[0]}"
    subnet_id = "${aws_subnet.public.id}"
    vpc_security_group_ids = [aws_security_group.sec_grp_web.id]
    key_name = "${aws_key_pair.generated_key.key_name}"

    tags = {
        Name = " web_os"
    }

    depends_on = [ tls_private_key.mykey, aws_vpc.custom_vpc, aws_security_group.sec_grp_web, aws_subnet.public, aws_internet_gateway.custom_igww ] 

}
  


## to login into instance and run tthe commands for installation of pkg's & enabling services

resource "null_resource" "after_os_creation"  {

  depends_on = [
    aws_instance.web
  ]

  connection {
    type     = "ssh"
    user     = "ec2-user"
    private_key = "${tls_private_key.mykey.private_key_pem}"
    host     = "${aws_instance.web.public_ip}"
  }

  provisioner "remote-exec" {
    inline = [
      "sudo yum install -y amazon-efs-utils",
      "sudo yum install -y nfs-common",
      "sudo yum install -y nfs-utils",
      "sudo yum install httpd git -y",
      "sudo systemctl restart httpd",
      "sudo systemctl enable httpd"
    ]
  }  
}


## To create a EFS


resource "aws_efs_file_system" "myefs" {
  depends_on = [
    null_resource.after_os_creation
  ]
  tags = {
    Name = "myEFS"
  }
}



## To create mount target


resource "aws_efs_mount_target" "efs_mount" {
  depends_on = [
    aws_efs_file_system.myefs
  ]
  file_system_id = aws_efs_file_system.myefs.id
  subnet_id = aws_subnet.public.id
  security_groups = [ aws_security_group.sec_grp_web.id ]
}



## To create a bucket


resource "aws_s3_bucket" "EFS_bucket" {

  depends_on = [
    aws_efs_file_system.myefs
  ]
  bucket = "efsbucket111222333"
  acl    = "public-read"
  region = "ap-south-1"
  force_destroy = "true"
  website{
    index_document = "index.html"
  }
  versioning {
  enabled = true
  }

  tags = {
    Name = "EFS_bucket"
  }
}



### creating the cloudFront for  faster image access

resource "aws_cloudfront_origin_access_identity" "origin_access_identity" {
  comment = "creating OAI"
}


locals {
  s3_origin_id = "myS3Origin11112222"
}


resource "aws_cloudfront_distribution" "s3_distribution" {

    depends_on = [
      aws_efs_file_system.myefs,
      aws_s3_bucket.EFS_bucket
    ]

  origin {
    domain_name = "${aws_s3_bucket.EFS_bucket.bucket_regional_domain_name}"
    origin_id   = "${local.s3_origin_id}"

    s3_origin_config {
      origin_access_identity = "${aws_cloudfront_origin_access_identity.origin_access_identity.cloudfront_access_identity_path}"
    }
  }


  enabled             = true
  is_ipv6_enabled     = true


  default_cache_behavior {
    allowed_methods  = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "${local.s3_origin_id}"

    forwarded_values {
      query_string = false

      cookies {
        forward = "none"
      }
    }

    viewer_protocol_policy = "redirect-to-https"
    min_ttl                = 0
    default_ttl            = 3600
    max_ttl                = 86400
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  tags = {
    Environment = "production"
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }


}


## creating the policy for bucket to allow OAI created by cloudFront for access the S3 images


data "aws_iam_policy_document" "s3_policy" {

  statement {
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.EFS_bucket.arn}/*"]

    principals {
      type        = "AWS"
      identifiers = ["${aws_cloudfront_origin_access_identity.origin_access_identity.iam_arn}"]
    }
  }

  statement {
    actions   = ["s3:ListBucket"]
    resources = ["${aws_s3_bucket.EFS_bucket.arn}"]

    principals {
      type        = "AWS"
      identifiers = ["${aws_cloudfront_origin_access_identity.origin_access_identity.iam_arn}"]
    }
  }
}


resource "aws_s3_bucket_policy" "policy_for_EFS_bucket" {
  bucket = "${aws_s3_bucket.EFS_bucket.id}"
  policy = "${data.aws_iam_policy_document.s3_policy.json}"
}


resource "null_resource" "null_resource_for_clone" {

    depends_on = [
      aws_cloudfront_distribution.s3_distribution,
    ]

    connection {
      type = "ssh"
      user = "ec2-user"
      private_key =  "${tls_private_key.mykey.private_key_pem}"
      host = aws_instance.web.public_ip
    }    
    
    provisioner "remote-exec" {

  
      inline = [
        "sudo mount -t nfs4 -o nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2,noresvport ${aws_efs_mount_target.efs_mount.ip_address}:/ /var/www/html",
        "sudo su -c \"echo '${aws_efs_mount_target.efs_mount.ip_address}:/ /var/www/html nfs4 defaults,vers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2,noresvport 0 0' >> /etc/fstab\"",
        "sudo rm -rf  /var/www/html/.* 2> /dev/null",
        "sudo rm -rf /var/www/html/*",
        "sudo git clone https://github.com/mohamedafrid-lab/Terraform-test.git /var/www/html/",
        "sudo sed -i 's/CF_URL_Here/${aws_cloudfront_distribution.s3_distribution.domain_name}/' /var/www/html/index.html",
        "sudo systemctl restart httpd",
      ]
    }
}





## To create a policy and role 


resource "aws_iam_role" "codepipeline_admin_role" {
  name = "codepipeline_admin_role"

  assume_role_policy = <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
    {
        "Action": "sts:AssumeRole",
        "Principal": {
            "Service": "codepipeline.amazonaws.com"
        },
        "Effect": "Allow",
        "Sid": ""
    }
    ]
}
EOF
}


resource "aws_iam_policy" "codepipeline_policy" {
  name        = "codepipeline_policy"
  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "*",
      "Resource": "*"
    }
  ]
}
EOF
}




## To attach a policy to role 


resource "aws_iam_role_policy_attachment" "attach-policies" {
  role       = "${aws_iam_role.codepipeline_admin_role.id}"
  policy_arn = "${aws_iam_policy.codepipeline_policy.arn}"
}



## To create a code pipeline

resource "aws_codepipeline" "task_codepipeline" {

    depends_on = [
        aws_s3_bucket.EFS_bucket
    ]
   name = "EFS_task_codepipeline"
   role_arn = "${aws_iam_role.codepipeline_admin_role.arn}"
   artifact_store {
    location = aws_s3_bucket.EFS_bucket.bucket
    type = "S3"
  }
  stage {
    name = "Source"
    
    action {
      name = "Source"
      category = "Source"
      owner = "ThirdParty"
      provider = "GitHub"
      version = "1"
      output_artifacts = ["source_output"]
      
      configuration = {
        Owner = "mohamedafrid-lab"
        Repo = "Terraform-test"
        Branch = "master"
        OAuthToken = "90ac860ba2cf0005da6f1f83d277bfe8df30072b"
      }
    }
  }
  
  stage {
    name = "Deploy"

    action {
      name = "Deploy"
      category = "Deploy"
      owner = "AWS"
      provider = "S3"
      version = "1"
      input_artifacts = ["source_output"]

      configuration = {
        BucketName = "${aws_s3_bucket.EFS_bucket.bucket}"
        Extract = "true"
      }
    }
  }
}



