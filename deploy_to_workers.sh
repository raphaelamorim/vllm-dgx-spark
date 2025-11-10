#!/bin/bash
# Deploy scripts to all worker nodes

# List your worker IPs here
WORKERS=(
  "192.168.1.100"  # Replace with your worker IP
  # "192.168.1.101"  # Uncomment and add more workers
  # "192.168.1.102"
)

USERNAME="your-username"  # Change to your SSH username

echo "Deploying scripts to ${#WORKERS[@]} worker(s)..."

for worker in "${WORKERS[@]}"; do
  echo "Copying to $worker..."
  
  # Copy the worker script
  scp start_worker_vllm.sh ${USERNAME}@${worker}:~/ && \

  # Make it executable
  ssh ${USERNAME}@${worker} "chmod +x ~/start_worker_vllm.sh" && \
  
  echo "✅ $worker complete" || echo "❌ $worker failed"
done

echo ""
echo "Deployment complete!"
