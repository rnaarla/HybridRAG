#!/bin/bash

# Deploy RAG Pipeline Infrastructure
# Usage: ./deploy.sh <environment>

set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Error handling
handle_error() {
    local exit_code=$?
    local line_number=$1
    log_error "Failed at line $line_number with exit code $exit_code"
    exit $exit_code
}

trap 'handle_error ${LINENO}' ERR

# Check required tools and AWS configuration
check_prerequisites() {
    local missing_tools=()
    
    if ! command -v cfn-lint &> /dev/null; then
        missing_tools+=("cfn-lint")
    fi
    
    if ! command -v aws &> /dev/null; then
        missing_tools+=("aws-cli")
    fi
    
    if [ ${#missing_tools[@]} -ne 0 ]; then
        log_error "Missing required tools: ${missing_tools[*]}"
        log_info "Please install missing tools:"
        log_info "cfn-lint: pip install cfn-lint"
        log_info "aws-cli: https://aws.amazon.com/cli/"
        exit 1
    fi

    # Check AWS configuration
    if ! aws configure list | grep -q "region"; then
        log_error "AWS CLI is not configured. Please run 'aws configure' first."
        exit 1
    fi

    # Get default region or set to us-east-2
    AWS_REGION=$(aws configure get region)
    if [ -z "$AWS_REGION" ]; then
        AWS_REGION="us-east-2"
        log_warning "No default region found in AWS configuration, using us-east-2"
        export AWS_DEFAULT_REGION=$AWS_REGION
    }
}

# Validate input
validate_input() {
    if [ "$#" -ne 1 ]; then
        log_error "Usage: $0 <environment>"
        log_error "Example: $0 dev"
        exit 1
    fi

    local env=$1
    if [[ ! "$env" =~ ^(dev|staging|prod)$ ]]; then
        log_error "Environment must be dev, staging, or prod"
        exit 1
    fi
}

# Validate templates with cfn-lint
validate_templates_cfn_lint() {
    local template_dir=$1
    local has_errors=0
    local templates=(
        "$template_dir/parent-stack.yaml"
        "$template_dir/nested-stacks/networking-stack.yaml"
        "$template_dir/nested-stacks/s3-stack.yaml"
        "$template_dir/nested-stacks/neptune-stack.yaml"
        "$template_dir/nested-stacks/opensearch-stack.yaml"
        "$template_dir/nested-stacks/compute-stack.yaml"
        "$template_dir/nested-stacks/monitoring-stack.yaml"
    )

    log_info "Validating CloudFormation templates with cfn-lint..."
    
    for template in "${templates[@]}"; do
        if [ ! -f "$template" ]; then
            log_error "Template file not found: $template"
            return 1
        fi

        log_info "Validating $template"
        if ! cfn-lint -t "$template" --ignore-checks W; then
            log_error "cfn-lint validation failed for $template"
            has_errors=1
        fi
    done

    if [ $has_errors -eq 1 ]; then
        log_error "cfn-lint validation failed for one or more templates"
        return 1
    fi
    
    log_info "cfn-lint validation completed successfully"
}

# Validate templates with AWS
validate_templates_aws() {
    local template_dir=$1
    local has_errors=0
    local templates=(
        "$template_dir/parent-stack.yaml"
        "$template_dir/nested-stacks/networking-stack.yaml"
        "$template_dir/nested-stacks/s3-stack.yaml"
        "$template_dir/nested-stacks/neptune-stack.yaml"
        "$template_dir/nested-stacks/opensearch-stack.yaml"
        "$template_dir/nested-stacks/compute-stack.yaml"
        "$template_dir/nested-stacks/monitoring-stack.yaml"
    )

    log_info "Validating CloudFormation templates with AWS..."
    
    for template in "${templates[@]}"; do
        if [ ! -f "$template" ]; then
            log_error "Template file not found: $template"
            return 1
        fi

        log_info "Validating $template"
        if ! aws cloudformation validate-template \
            --template-body "file://$template" > /dev/null; then
            log_error "AWS validation failed for $template"
            has_errors=1
        fi
    done

    if [ $has_errors -eq 1 ]; then
        log_error "AWS validation failed for one or more templates"
        return 1
    fi
    
    log_info "AWS validation completed successfully"
}

# Check if parameters file exists
check_parameters_file() {
    local env=$1
    local params_file="parameters/$env-parameters.json"
    
    if [ ! -f "$params_file" ]; then
        log_error "Parameters file not found: $params_file"
        exit 1
    fi
    
    # Validate JSON format
    if ! jq empty "$params_file" 2>/dev/null; then
        log_error "Invalid JSON in parameters file: $params_file"
        exit 1
    fi
}

# Main deployment function
deploy_stack() {
    local env=$1
    local stack_name="rag-pipeline-$env"
    local deployment_bucket="$stack_name-deployment"
    local template_dir="."

    # Create deployment bucket if it doesn't exist
    if ! aws s3 ls "s3://$deployment_bucket" 2>&1 > /dev/null; then
        log_info "Creating deployment bucket: $deployment_bucket"
        aws s3 mb "s3://$deployment_bucket"
    fi

    # Package nested stacks
    log_info "Packaging nested stacks..."
    aws cloudformation package \
        --template-file "$template_dir/parent-stack.yaml" \
        --s3-bucket "$deployment_bucket" \
        --output-template-file packaged-template.yaml

    # Deploy the stack
    log_info "Deploying stack: $stack_name"
    if ! aws cloudformation deploy \
        --template-file packaged-template.yaml \
        --stack-name "$stack_name" \
        --parameter-overrides "file://parameters/$env-parameters.json" \
        --capabilities CAPABILITY_NAMED_IAM \
        --tags "file://parameters/$env-parameters.json" \
        --no-fail-on-empty-changeset; then
        log_error "Stack deployment failed"
        exit 1
    fi

    # Wait for stack completion
    log_info "Waiting for stack deployment to complete..."
    if ! aws cloudformation wait stack-create-complete \
        --stack-name "$stack_name" 2>/dev/null || \
       ! aws cloudformation wait stack-update-complete \
        --stack-name "$stack_name" 2>/dev/null; then
        log_error "Stack deployment failed or timed out"
        exit 1
    fi

    # Output stack details
    log_info "Deployment complete! Stack outputs:"
    aws cloudformation describe-stacks \
        --stack-name "$stack_name" \
        --query 'Stacks[0].Outputs' \
        --output table
}

# Main execution
main() {
    local env=$1

    log_info "Using AWS Region: $AWS_REGION"

    # Run validations
    check_prerequisites
    validate_input "$env"
    check_parameters_file "$env"
    validate_templates_cfn_lint "."
    validate_templates_aws "."

    # Deploy stack
    deploy_stack "$env"

    log_info "RAG Pipeline deployment to $env completed successfully!"
}

# Execute main with provided arguments
main "$@"