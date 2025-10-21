#!/bin/bash

# Logging to timestamped file
LOG_FILE="deploy_$(date +%Y%m%d).log"
exec > >(tee -a "$LOG_FILE") 2>&1

# Exit codes
SUCCESS=0
INVALID_INPUT=1
SSH_FAILED=2
GIT_FAILED=3
DOCKER_FAILED=4
NGINX_FAILED=5

# Error handling with trap
handle_error() {
    echo "DEPLOYMENT FAILED at line $1"
    echo "Check log file: $LOG_FILE"
    exit $SSH_FAILED
}
trap 'handle_error $LINENO' ERR

# Cleanup function
cleanup() {
    echo "Cleaning up temporary files..."
    rm -rf "$TEMP_DIR" 2>/dev/null || true
}
trap cleanup EXIT
# ===========================================================

echo "=== HNG Stage 1 Deployment Started: $(date) ==="

# Parameters from user input
echo "Please enter the following details"
read -p "Git Repository URL: " git_url
read -p "Personal Access Token: " git_token
read -p "Branch Name: " branch_name
read -p "Server Username: " server_user
read -p "Server IP Address: " server_ip
read -p "SSH Key Path: " ssh_key
read -p "Application Port: " app_port

echo "Got all information, starting deployment"
echo "............................................."

# Clone the Repo
echo "Downloading your code from GitHub..."

# For Private Repo
if [ -n "$git_token" ]; then
    auth_url=$(echo "$git_url" | sed "s|https://|https://token:$git_token@|")
    git clone -b $branch_name $auth_url app-code

    # Public Repo
else
    git clone -b $branch_name $git_url app-code
fi

# Check if clone was successful
if [ $? -ne 0 ]; then
    echo "Failed to clone repository!"
    exit 1
fi

# Navigate into the Cloned Repo and Verify Docker exists
cd app-code
if [ -f "Dockerfile" ]; then
    echo "Found Dockerfile"
elif [ -f "docker-compose.yml" ]; then
    echo "Found docker-compose.yml"
else
    echo "Error: No Dockerfile or docker-compose.yml found!"
    exit 1
fi
cd ..
echo "Code downloaded successfully!"

# SSH into Remote Server 
echo "Setting up Server..."
ssh -i $ssh_key $server_user@$server_ip "
    echo 'Updating system packages...'
    sudo apt update && sudo apt upgrade -y
    
    echo 'Installing Docker...'
    sudo apt install docker.io -y
    
    echo 'Installing Nginx...'
    sudo apt install nginx -y
    
    echo 'Starting services...'
    sudo systemctl start docker
    sudo systemctl enable docker
    sudo systemctl start nginx
    sudo systemctl enable nginx
    
    echo 'Adding user to docker group...'
    sudo usermod -aG docker $server_user
    echo 'Note: You may need to logout/login for docker group changes'
    
    echo 'Server setup complete!'
"

# Deploy Dockerized Application
echo "Sending your code to the server..."
scp -i $ssh_key -r app-code $server_user@$server_ip:/home/$server_user/
echo "Deploying your application..."
ssh -i $ssh_key $server_user@$server_ip "
    cd /home/$server_user/app-code
    echo 'Stopping any existing containers...'
    sudo docker stop my-app-container 2>/dev/null || echo 'No existing container'
    sudo docker rm my-app-container 2>/dev/null || echo 'No container to remove'
    if [ -f 'docker-compose.yml' ]; then
        echo 'Using docker-compose...'
        sudo docker-compose down 2>/dev/null || true
        sudo docker-compose up --build -d
    else
        echo 'Using Dockerfile...'
        sudo docker build -t my-app .
        sudo docker run -d -p $app_port:$app_port --name my-app-container my-app
    fi
    
    echo 'Waiting for app to start...'
    sleep 15
    
    echo 'Checking if app is running...'
    sudo docker ps
"

# Configure Nginx as a Reverse Proxy
echo "Configuring Nginx reverse proxy..."
echo "Configuring Nginx reverse proxy..."

ssh -i $ssh_key $server_user@$server_ip "
    # Create Nginx configuration
    sudo tee /etc/nginx/sites-available/my-app > /dev/null <<EOF
server {
    listen 80;
    server_name $server_ip;
    
    location / {
        proxy_pass http://localhost:$app_port;
        proxy_set_header Host \\\$host;
        proxy_set_header X-Real-IP \\\$remote_addr;
        proxy_set_header X-Forwarded-For \\\$proxy_add_x_forwarded_for;
    }
}
EOF

    # Enable the site
    sudo ln -sf /etc/nginx/sites-available/my-app /etc/nginx/sites-enabled/
    
    # Remove default Nginx site
    sudo rm -f /etc/nginx/sites-enabled/default
    
    # Test configuration
    sudo nginx -t
    
    # Reload Nginx
    sudo systemctl reload nginx
    
    echo 'Nginx configured!'
"

# Test deployment
echo "Testing deployment..."
if curl -s -f "http://$server_ip" > /dev/null; then
    echo "SUCCESS! Your app is live at: http://$server_ip"
else
    echo "Deployment might need manual checking"
    echo "Check: http://$server_ip"
fi

echo "................................"
echo "DEPLOYMENT COMPLETED!"
echo "Your application: http://$server_ip"
echo "Docker containers are running on port: $app_port"
echo "Nginx is proxying traffic from port 80 to $app_port"


