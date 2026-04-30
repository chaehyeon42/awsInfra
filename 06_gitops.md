
단계 5의 모듈 코드를 Git으로 관리하고, PR을 올리면 `terraform plan`이 자동 실행되고 main 브랜치에 머지되면 `terraform apply`가 자동으로 실행되는 GitOps 파이프라인을 구성합니다.

---

## 왜 GitOps가 필요한가?

단계 5까지는 로컬 PC에서 직접 `terraform apply`를 실행했습니다.  
팀이 커지면 "누가 언제 무엇을 apply 했는지" 추적이 불가능해지고, 실수로 잘못된 코드를 apply할 위험이 생깁니다.

```
# 기존 방식 (단계 5까지)
로컬 PC → terraform apply → AWS

# GitOps 방식 (단계 6)
Git PR 생성 → GitHub Actions: terraform plan → PR 코멘트로 결과 게시
Git main 머지 → GitHub Actions: terraform apply → AWS
```

변경 이력이 Git 커밋에 남고, plan 결과를 팀원이 PR에서 검토한 뒤 머지할 수 있습니다.

---

## 전체 흐름

```
1. feature 브랜치에서 .tf 파일 수정
2. PR 생성
   └── GitHub Actions: terraform plan 실행
   └── 결과를 PR 코멘트로 자동 게시
3. 팀원 코드 리뷰 + plan 결과 확인 후 승인
4. main 브랜치로 머지
   └── GitHub Actions: terraform apply 실행
   └── AWS 인프라 실제 변경
```

---

## 파일 구조

```
lab06/
├── .github/
│   └── workflows/
│       └── terraform.yml    ← 핵심: CI/CD 파이프라인 정의
├── provider.tf
├── variables.tf
├── terraform.tfvars
├── main.tf
├── outputs.tf
└── modules/
    └── network/
        ├── main.tf
        ├── variables.tf
        └── outputs.tf
```

---

## 사전 준비: S3 버킷 + DynamoDB 테이블 생성

`terraform init` 시 `S3 bucket does not exist` 오류가 나는 것은 Remote State 저장소가 없기 때문입니다.  
**GitHub Actions 워크플로우 실행 전에 로컬 PC에서 한 번만 실행**하면 됩니다.

```powershell
# S3 버킷 생성
aws s3api create-bucket `
    --bucket myapp-terraform-state-20260429 `
    --region ap-northeast-2 `
    --create-bucket-configuration LocationConstraint=ap-northeast-2

# 버전 관리 활성화 (state 파일 이력 보존)
aws s3api put-bucket-versioning `
    --bucket myapp-terraform-state-20260429 `
    --versioning-configuration Status=Enabled

# DynamoDB Lock 테이블 생성 (동시 apply 충돌 방지)
aws dynamodb create-table `
    --table-name terraform-lock `
    --attribute-definitions AttributeName=LockID,AttributeType=S `
    --key-schema AttributeName=LockID,KeyType=HASH `
    --billing-mode PAY_PER_REQUEST `
    --region ap-northeast-2
```

생성 확인:

```powershell
# 버킷 존재 확인
aws s3 ls | Select-String myapp-terraform-state

# DynamoDB 테이블 확인
aws dynamodb describe-table --table-name terraform-lock --query "Table.TableStatus"
```

> 단계 3 (RemoteState)에서 이미 생성했다면 이 단계는 건너뜁니다.

---

## GitHub Secrets 설정

GitHub 저장소 → Settings → Secrets and variables → Actions 에서 아래 항목을 등록합니다.

| Secret 이름 | 값 | 예시 |
|------------|-----|------|
| `AWS_ACCESS_KEY_ID` | IAM 사용자 액세스 키 | `AKIAIOSFODNN7EXAMPLE` |
| `AWS_SECRET_ACCESS_KEY` | IAM 사용자 시크릿 키 | `wJalrXUtnFEMI/K7MDENG/...` |
| `KEY_PAIR_NAME` | AWS EC2 키페어 이름 | `MyCliKeyPair` |

키페어 이름 확인:
```powershell
aws ec2 describe-key-pairs --query "KeyPairs[].KeyName" --output table
```

> IAM 사용자는 Terraform이 다루는 리소스(VPC, EC2, S3, DynamoDB 등)에 대한 권한이 있어야 합니다.  
> `KEY_PAIR_NAME`을 Secret으로 관리하면 저장소를 공유해도 키페어 이름이 코드에 노출되지 않습니다.

---

## .github/workflows/terraform.yml

```yaml
name: Terraform GitOps

on:
  push:
    branches: [ "main" ]
  pull_request:
    branches: [ "main" ]

env:
  AWS_REGION: ap-northeast-2
  TF_WORKING_DIR: .

jobs:
  terraform:
    name: Terraform Plan / Apply
    runs-on: ubuntu-latest
    permissions:
      contents: read
      pull-requests: write   # PR 코멘트 게시 권한

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
          aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
          aws-region: ${{ env.AWS_REGION }}

      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: "1.7.0"

      - name: Terraform Init
        working-directory: ${{ env.TF_WORKING_DIR }}
        run: terraform init

      - name: Terraform Format Check
        working-directory: ${{ env.TF_WORKING_DIR }}
        run: terraform fmt -check

      - name: Terraform Validate
        working-directory: ${{ env.TF_WORKING_DIR }}
        run: terraform validate

      # PR일 때: plan 실행 후 결과를 PR 코멘트로 게시
      - name: Terraform Plan
        if: github.event_name == 'pull_request'
        id: plan
        working-directory: ${{ env.TF_WORKING_DIR }}
        run: terraform plan -no-color -var="key_pair_name=${{ secrets.KEY_PAIR_NAME }}"
        continue-on-error: true

      - name: Post Plan Result to PR
        if: github.event_name == 'pull_request'
        uses: actions/github-script@v7
        with:
          script: |
            const output = `#### Terraform Plan \`${{ steps.plan.outcome }}\`
            <details><summary>계획 결과 보기</summary>

            \`\`\`
            ${{ steps.plan.outputs.stdout }}
            \`\`\`
            </details>

            *작성자: @${{ github.actor }}, 워크플로우: \`${{ github.workflow }}\`*`;

            github.rest.issues.createComment({
              issue_number: context.issue.number,
              owner: context.repo.owner,
              repo: context.repo.repo,
              body: output
            })

      - name: Plan 실패 시 워크플로우 중단
        if: github.event_name == 'pull_request' && steps.plan.outcome == 'failure'
        run: exit 1

      # main 머지 시: apply 자동 실행
      - name: Terraform Apply
        if: github.ref == 'refs/heads/main' && github.event_name == 'push'
        working-directory: ${{ env.TF_WORKING_DIR }}
        run: terraform apply -auto-approve -var="key_pair_name=${{ secrets.KEY_PAIR_NAME }}"
```

---

## provider.tf (Remote State 연결)

```hcl
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket         = "myapp-terraform-state-20260429"
    key            = "training/lab06/terraform.tfstate"
    region         = "ap-northeast-2"
    encrypt        = true
    dynamodb_table = "terraform-lock"
  }
}

provider "aws" {
  region = var.region
}
```

---

## variables.tf

```hcl
variable "region" {
  default = "ap-northeast-2"
}

variable "project" {
  default = "myapp"
}

variable "environment" {
  default = "dev"
}

variable "key_pair_name" {
  description = "EC2 접속용 키페어 이름"
  type        = string
}
```

---

## terraform.tfvars

```hcl
project       = "myapp"
environment   = "dev"
key_pair_name = "MyCliKeyPair"
```

> `key_pair_name`은 GitHub Actions 워크플로우에서 `-var` 플래그로도 전달합니다.  
> 민감한 값은 `.tfvars` 파일 대신 GitHub Secrets + `-var` 방식을 사용하세요.

---

## main.tf

단계 5와 동일한 코드입니다. 인프라 코드 자체는 변경 없이 파이프라인만 추가한 것이 이번 단계의 핵심입니다.

```hcl
module "network" {
  source = "./modules/network"

  project             = var.project
  environment         = var.environment
  region              = var.region
  vpc_cidr            = "10.0.0.0/16"
  public_subnet_cidr  = "10.0.1.0/24"
  private_subnet_cidr = "10.0.2.0/24"
}

resource "aws_security_group" "backend" {
  name   = "${var.project}-backend-sg"
  vpc_id = module.network.vpc_id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 8080
    to_port     = 8080
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

data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }
}

resource "aws_instance" "backend" {
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = "t2.micro"
  subnet_id              = module.network.public_subnet_id
  vpc_security_group_ids = [aws_security_group.backend.id]
  key_name               = var.key_pair_name

  tags = {
    Name        = "${var.project}-backend"
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}
```

---

## outputs.tf

```hcl
output "vpc_id" {
  value = module.network.vpc_id
}

output "backend_public_ip" {
  value = aws_instance.backend.public_ip
}
```

---

## 실습 순서

```bash
# 1. GitHub 저장소 생성 후 lab06 디렉터리 push
git init
git add .
git commit -m "feat: lab06 gitops terraform"
git remote add origin https://github.com/<your-org>/<your-repo>.git
git push -u origin main

# 2. feature 브랜치에서 변경 (예: instance_type 변경)
git checkout -b feature/change-instance-type
# main.tf에서 t2.micro → t3.micro 로 수정
git add main.tf
git commit -m "change: EC2 instance type t2.micro → t3.micro"
git push origin feature/change-instance-type

# 3. GitHub에서 PR 생성
# → GitHub Actions가 terraform plan 자동 실행
# → PR 코멘트에 plan 결과가 게시됨

# 4. 팀원 리뷰 후 main으로 머지
# → GitHub Actions가 terraform apply 자동 실행
# → AWS EC2 인스턴스 타입 변경됨
```

---

## 단계별 비교

| 항목 | 단계 5 (모듈 사용) | 단계 6 (GitOps) |
|------|-----------------|----------------|
| apply 실행 방법 | 로컬 PC에서 직접 | GitHub Actions 자동화 |
| 변경 이력 관리 | 없음 | Git 커밋 + PR 이력 |
| plan 결과 공유 | 없음 | PR 코멘트 자동 게시 |
| 팀 협업 | 불가 | PR 리뷰 후 머지 |
| AWS 자격증명 위치 | 로컬 `~/.aws` | GitHub Secrets |