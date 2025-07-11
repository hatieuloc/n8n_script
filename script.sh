#!/bin/bash

set -e  # Exit on any error

# --- Default Global variables ---
DOMAIN="n8n.loctieuha.com" # Default domain
EMAIL="admin@loctieuha.com"
MODE="dev" # Default mode is 'dev'

# --- Colors for output ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' 

# --- Logging Functions ---
log() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"
}
success() {
    echo -e "${GREEN}[SUCCESS] $1${NC}"
}
warning() {
    echo -e "${YELLOW}[WARNING] $1${NC}"
}
error() {
    echo -e "${RED}[ERROR] $1${NC}"
    exit 1
}

# --- Usage and Argument Parsing ---
show_usage() {
    echo "Usage: $0 --domain=\"your-domain.com\" --email=\"your-email@gmail.com\" [--mode=\"dev|live\"]"
    echo ""
    echo "Arguments:"
    echo "  --domain    Your domain name (e.g., n8n.example.com)"
    echo "  --email     Your email for SSL registration"
    echo "  --mode      Environment mode: 'dev' (default) or 'live'"
    echo ""
    echo "Example (Dev):   $0 --domain=\"dev.n8n.com\" --email=\"user@gmail.com\" --mode=dev"
    echo "Example (Live):  $0 --domain=\"n8n.com\" --email=\"user@gmail.com\" --mode=live"
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --domain=*)
                DOMAIN="${1#*=}"
                shift
                ;;
            --email=*)
                EMAIL="${1#*=}"
                shift
                ;;
            --mode=*)
                MODE="${1#*=}"
                shift
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            *)
                error "Unknown argument: $1. Use --help for usage."
                ;;
        esac
    done
}

# --- Validation Functions ---
validate_domain() {
    [[ -n "$1" && "$1" =~ ^[a-zA-Z0-9.-]+$ && "$1" =~ \. ]]
}

validate_email() {
    [[ -n "$1" && "$1" =~ ^[^@]+@[^@]+\.+[^@]+$ ]]
}

validate_inputs() {
    log "Validating inputs..."
    if ! validate_domain "$DOMAIN"; then
        error "Invalid or missing domain. Use --domain=\"your-domain.com\""
    fi
    if ! validate_email "$EMAIL"; then
        error "Invalid or missing email. Use --email=\"your-email@gmail.com\""
    fi
    if [[ "$MODE" != "dev" && "$MODE" != "live" ]]; then
        error "Invalid mode: '$MODE'. Use --mode=\"dev\" or --mode=\"live\""
    fi
    success "Inputs validated:"
    echo -e "  - Domain: ${GREEN}$DOMAIN${NC}"
    echo -e "  - Email:  ${GREEN}$EMAIL${NC}"
    echo -e "  - Mode:   ${GREEN}$MODE${NC}"
}

# --- Prerequisite Installation Functions ---
check_os_support() {
    log "Checking operating system..."
    if [[ ! -f /etc/os-release ]] || ! source /etc/os-release || [[ "$ID" != "ubuntu" ]]; then
        error "This script only supports Ubuntu."
    fi
    success "Ubuntu OS detected."
}

install_prerequisites() {
    log "Installing prerequisites (curl, wget, gnupg, docker, nginx, certbot)..."
    sudo apt-get update -y > /dev/null 2>&1
    sudo apt-get install -y curl wget apt-transport-https ca-certificates gnupg lsb-release software-properties-common > /dev/null 2>&1
    
    # Install Docker
    if ! command -v docker &> /dev/null; then
        sudo install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        sudo chmod a+r /etc/apt/keyrings/docker.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
        sudo apt-get update -y > /dev/null 2>&1
        sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin > /dev/null 2>&1
        sudo systemctl start docker && sudo systemctl enable docker
    fi

    # Install Nginx
    sudo apt-get install -y nginx > /dev/null 2>&1
    # Install Certbot
    sudo apt-get install -y certbot python3-certbot-nginx > /dev/null 2>&1
    success "All prerequisites are installed."
}

# --- Environment Setup Functions ---
setup_environment() {
    log "Setting up environment for '$MODE' mode..."
    
    # Safety check
    if [ -f docker-compose.yml ] || [ -f .env ]; then
        error "Existing 'docker-compose.yml' or '.env' file found. Please remove them before running to prevent data loss."
    fi

    if [ "$MODE" == "dev" ]; then
        # For dev, create a docker-compose with n8n and postgres
        log "Generating docker-compose.yml for development..."
        cat > docker-compose.yml << EOF
version: '3.8'

services:
  postgres:
    image: postgres:13
    restart: always
    environment:
      - POSTGRES_USER=\${DB_USER}
      - POSTGRES_PASSWORD=\${DB_PASSWORD}
      - POSTGRES_DB=\${DB_DATABASE}
    volumes:
      - postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U \${DB_USER} -d \${DB_DATABASE}"]
      interval: 5s
      timeout: 5s
      retries: 10

  n8n:
    image: n8nio/n8n
    restart: always
    ports:
      - "127.0.0.1:5678:5678"
    environment:
      - N8N_HOST=\${N8N_HOST}
      - WEBHOOK_URL=\${WEBHOOK_URL}
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=postgres
      - DB_POSTGRESDB_PORT=5432
      - DB_POSTGRESDB_USER=\${DB_USER}
      - DB_POSTGRESDB_PASSWORD=\${DB_PASSWORD}
      - DB_POSTGRESDB_DATABASE=\${DB_DATABASE}
    volumes:
      - n8n_data:/home/node/.n8n
    depends_on:
      postgres:
        condition: service_healthy

volumes:
  n8n_data:
  postgres_data:
EOF
        log "Generating .env file for development..."
        # Generate a random password for the dev database
        DB_PASSWORD_RANDOM=$(openssl rand -base64 16)
        cat > .env << EOF
# Development Environment for n8n

# === PostgreSQL Settings ===
DB_USER=n8n_dev_user
DB_PASSWORD=${DB_PASSWORD_RANDOM}
DB_DATABASE=n8n_dev_db

# === n8n Settings ===
N8N_HOST=${DOMAIN}
WEBHOOK_URL=https://${DOMAIN}/
EOF
        success "Dev environment created. A random password has been set for the database."

    elif [ "$MODE" == "live" ]; then
        # For live, create a docker-compose with only n8n
        log "Generating docker-compose.yml for production..."
        cat > docker-compose.yml << EOF
version: '3.8'

services:
  n8n:
    image: n8nio/n8n
    restart: always
    ports:
      - "127.0.0.1:5678:5678"
    environment:
      - N8N_HOST=\${N8N_HOST}
      - WEBHOOK_URL=\${WEBHOOK_URL}
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=\${DB_HOST}
      - DB_POSTGRESDB_PORT=\${DB_PORT}
      - DB_POSTGRESDB_USER=\${DB_USER}
      - DB_POSTGRESDB_PASSWORD=\${DB_PASSWORD}
      - DB_POSTGRESDB_DATABASE=\${DB_DATABASE}
    volumes:
      - n8n_data:/home/node/.n8n

volumes:
  n8n_data:
EOF
        log "Generating .env file for production..."
        cat > .env << EOF
# Production Environment for n8n
# !!! IMPORTANT: Please fill in your production database credentials below !!!

# === PostgreSQL Settings ===
DB_HOST=your_database_host_or_ip
DB_PORT=5432
DB_USER=your_production_user
DB_PASSWORD=your_production_password
DB_DATABASE=your_production_database

# === n8n Settings ===
N8N_HOST=${DOMAIN}
WEBHOOK_URL=https://${DOMAIN}/
EOF
        warning "Production '.env' file created. Please edit it NOW and fill in your database credentials."
        read -p "Press [Enter] to continue after you have saved your changes to the .env file..."
    fi
    success "Environment setup complete."
}

# --- Deployment Functions ---
verify_dns() {
    log "Verifying DNS for $DOMAIN..."
    local server_ip=$(curl -s ifconfig.me)
    local domain_ip=$(dig +short "$DOMAIN" | head -1)
    if [[ "$server_ip" != "$domain_ip" ]]; then
        error "DNS Mismatch! Domain '$DOMAIN' points to '$domain_ip', but server IP is '$server_ip'. Please fix your DNS A record."
    fi
    success "DNS verification passed."
}

deploy_n8n() {
    log "Deploying n8n with Docker Compose..."
    sudo docker compose up -d
    success "n8n deployment started in the background."
}

# --- Nginx and SSL Functions ---
configure_nginx_and_ssl() {
    log "Configuring Nginx and obtaining SSL certificate..."
    local config_file="/etc/nginx/sites-available/$DOMAIN"

    log "Creating Nginx configuration for $DOMAIN..."
    sudo tee "$config_file" > /dev/null << EOF
server {
    listen 80;
    server_name $DOMAIN;

    # Allow certbot renewal
    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}
EOF
    sudo ln -sf "$config_file" "/etc/nginx/sites-enabled/$DOMAIN"
    sudo rm -f /etc/nginx/sites-enabled/default
    
    log "Testing Nginx configuration..."
    if ! sudo nginx -t; then
        error "Nginx configuration test failed."
    fi
    
    log "Restarting Nginx to apply HTTP config..."
    sudo systemctl restart nginx

    log "Obtaining SSL certificate with Certbot..."
    sudo certbot --nginx --agree-tos --redirect --hsts --staple-ocsp --email "$EMAIL" -d "$DOMAIN" --non-interactive
    
    success "Nginx and SSL configured successfully."
}

# --- Main Execution ---
main() {
    parse_arguments "$@"
    validate_inputs
    check_os_support
    
    log "--- Phase 1: Prerequisites ---"
    install_prerequisites
    
    log "--- Phase 2: Environment Setup ---"
    setup_environment
    
    log "--- Phase 3: Deployment ---"
    verify_dns
    deploy_n8n
    
    log "--- Phase 4: Nginx & SSL ---"
    configure_nginx_and_ssl
    
    log "🎉 Installation Complete!"
    log "Access your n8n instance at: https://$DOMAIN"
    log "Your configuration is in 'docker-compose.yml' and '.env' files."
    log "To manage your deployment, use 'sudo docker compose [up, down, logs, etc.]"
}

main "$@"