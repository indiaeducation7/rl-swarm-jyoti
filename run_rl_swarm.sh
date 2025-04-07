#!/bin/bash

#General args
ROOT=$PWD

export PUB_MULTI_ADDRS
export PEER_MULTI_ADDRS
export HOST_MULTI_ADDRS
export IDENTITY_PATH
export CONNECT_TO_TESTNET=True  # Auto-answer "Y" for testnet connection
export ORG_ID
export HF_HUB_DOWNLOAD_TIMEOUT=120  # 2 minutes

#Check if public multi-address is given else set to default
DEFAULT_PUB_MULTI_ADDRS=""
PUB_MULTI_ADDRS=${PUB_MULTI_ADDRS:-$DEFAULT_PUB_MULTI_ADDRS}

#Check if peer multi-address is given else set to default
DEFAULT_PEER_MULTI_ADDRS="/ip4/38.101.215.13/tcp/30002/p2p/QmQ2gEXoPJg6iMBSUFWGzAabS2VhnzuS782Y637hGjfsRJ" # gensyn coordinator node
PEER_MULTI_ADDRS=${PEER_MULTI_ADDRS:-$DEFAULT_PEER_MULTI_ADDRS}

#Check if host multi-address is given else set to default
DEFAULT_HOST_MULTI_ADDRS="/ip4/0.0.0.0/tcp/38331"
HOST_MULTI_ADDRS=${HOST_MULTI_ADDRS:-$DEFAULT_HOST_MULTI_ADDRS}

# Path to an RSA private key. If this path does not exist, a new key pair will be created.
# Remove this file if you want a new PeerID.
DEFAULT_IDENTITY_PATH="$ROOT"/swarm.pem
IDENTITY_PATH=${IDENTITY_PATH:-$DEFAULT_IDENTITY_PATH}

# Removed interactive prompt and set CONNECT_TO_TESTNET=True automatically
echo ">>> Automatically connecting to Testnet (Y)"

if [ "$CONNECT_TO_TESTNET" = "True" ]; then
    # Install ngrok for more reliable tunneling
    echo "Installing ngrok..."
    wget https://bin.equinox.io/c/4VmDzA7iaHb/ngrok-stable-linux-amd64.zip
    unzip ngrok-stable-linux-amd64.zip
    chmod +x ngrok
    
    # Check if there's an auth token provided as environment variable
    if [ -z "$NGROK_AUTH_TOKEN" ]; then
        echo "No NGROK_AUTH_TOKEN found. Using ngrok without authentication (limited connections)."
    else
        echo "Configuring ngrok with provided auth token..."
        ./ngrok authtoken "$NGROK_AUTH_TOKEN"
    fi

    # run modal_login server
    echo "Please login to create an Ethereum Server Wallet"
    cd modal-login
    # Check if the yarn command exists; if not, install Yarn.
    source ~/.bashrc
    
    if ! command -v yarn >/dev/null 2>&1; then
        # Detect Ubuntu (including WSL Ubuntu) and install Yarn accordingly
        if grep -qi "ubuntu" /etc/os-release 2>/dev/null || uname -r | grep -qi "microsoft"; then
            echo "Detected Ubuntu or WSL Ubuntu. Installing Yarn via apt..."
            curl -sS https://dl.yarnpkg.com/debian/pubkey.gpg | sudo apt-key add -
            echo "deb https://dl.yarnpkg.com/debian/ stable main" | sudo tee /etc/apt/sources.list.d/yarn.list
            sudo apt update && sudo apt install -y yarn
        else
            echo "Yarn is not installed. Installing Yarn..."
            curl -o- -L https://yarnpkg.com/install.sh | sh
            echo 'export PATH="$HOME/.yarn/bin:$HOME/.config/yarn/global/node_modules/.bin:$PATH"' >> ~/.bashrc
            source ~/.bashrc
        fi
    fi
    yarn install
    
    # Examine the package.json to see if we need to make any changes to the server
    if [ -f "package.json" ]; then
        echo "Checking server setup in package.json..."
        grep -q "password" package.json && echo "Note: The server might have authentication enabled."
    fi
    
    # Start the server
    yarn dev > /dev/null 2>&1 & # Run in background and suppress output
    SERVER_PID=$!  # Store the process ID
    
    # Wait for server to be ready
    echo "Waiting for server to start..."
    sleep 5
    
    # Start ngrok in the background to create tunnel
    echo "Starting ngrok tunnel to expose localhost:3000..."
    cd ..
    ./ngrok http 3000 --log=stdout > ngrok.log &
    NGROK_PID=$!
    
    # Wait for ngrok to establish tunnel
    sleep 5
    
    # Extract ngrok URL
    NGROK_URL=$(grep -o "https://.*ngrok-free.app" ngrok.log | head -n 1)
    if [ -z "$NGROK_URL" ]; then
        # Try again with different pattern if the first didn't work
        NGROK_URL=$(grep -o "https://[0-9a-f]*\.ngrok\.io" ngrok.log | head -n 1)
    fi
    
    if [ -z "$NGROK_URL" ]; then
        echo "Could not find ngrok URL in logs. Please check ngrok.log for the URL."
        echo "You can run: cat ngrok.log | grep -o 'https://.*ngrok.*' to find it."
    else
        echo "================================================="
        echo "Access the login page at: $NGROK_URL"
        echo "================================================="
    fi

    # Wait until modal-login/temp-data/userData.json exists
    echo "Waiting for login completion..."
    while [ ! -f "modal-login/temp-data/userData.json" ]; do
        echo "Waiting for userData.json to be created... Please complete login via the ngrok URL."
        sleep 10  # Wait for 10 seconds before checking again
    done
    echo "userData.json found. Proceeding..."

    ORG_ID=$(awk 'BEGIN { FS = "\"" } !/^[ \t]*[{}]/ { print $(NF - 1); exit }' modal-login/temp-data/userData.json)
    echo "ORG_ID set to: $ORG_ID"

    # Wait until the API key is activated by the client
    echo "Waiting for API key to become activated..."
    while true; do
        STATUS=$(curl -s "http://localhost:3000/api/get-api-key-status?orgId=$ORG_ID")
        if [[ "$STATUS" == "activated" ]]; then
            echo "API key is activated! Proceeding..."
            break
        else
            echo "Waiting for API key to be activated..."
            sleep 5
        fi
    done

    # Function to clean up the server process
    cleanup() {
        echo "Shutting down server and tunnel..."
        kill $SERVER_PID 2>/dev/null
        kill $NGROK_PID 2>/dev/null
        rm -r modal-login/temp-data/*.json 2>/dev/null
        exit 0
    }

    # Set up trap to catch Ctrl+C and call cleanup
    trap cleanup INT
fi

#lets go!
echo "Getting requirements..."
pip install -r "$ROOT"/requirements-hivemind.txt > /dev/null
pip install -r "$ROOT"/requirements.txt > /dev/null

if ! which nvidia-smi; then
   #You don't have a NVIDIA GPU
   CONFIG_PATH="$ROOT/hivemind_exp/configs/mac/grpo-qwen-2.5-0.5b-deepseek-r1.yaml"
elif [ -n "$CPU_ONLY" ]; then
   # ... or we don't want to use it
   CONFIG_PATH="$ROOT/hivemind_exp/configs/mac/grpo-qwen-2.5-0.5b-deepseek-r1.yaml"
else
   #NVIDIA GPU found
   pip install -r "$ROOT"/requirements_gpu.txt > /dev/null
   CONFIG_PATH="$ROOT/hivemind_exp/configs/gpu/grpo-qwen-2.5-0.5b-deepseek-r1.yaml"
fi

echo ">> Done!"
echo ""
echo ""

# Auto-answer "N" for Hugging Face Hub question
HUGGINGFACE_ACCESS_TOKEN="None"
echo ">>> Automatically choosing NOT to push models to Hugging Face Hub (N)"

echo ""
echo ""
echo "Good luck in the swarm!"

if [ -n "$ORG_ID" ]; then
    python -m hivemind_exp.gsm8k.train_single_gpu \
        --hf_token "$HUGGINGFACE_ACCESS_TOKEN" \
        --identity_path "$IDENTITY_PATH" \
        --modal_org_id "$ORG_ID" \
        --config "$CONFIG_PATH"
else
    python -m hivemind_exp.gsm8k.train_single_gpu \
        --hf_token "$HUGGINGFACE_ACCESS_TOKEN" \
        --identity_path "$IDENTITY_PATH" \
        --public_maddr "$PUB_MULTI_ADDRS" \
        --initial_peers "$PEER_MULTI_ADDRS"\
        --host_maddr "$HOST_MULTI_ADDRS" \
        --config "$CONFIG_PATH"
fi

wait  # Keep script running until Ctrl+C
