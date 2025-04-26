// deploy.js
const fs = require('fs');
const path = require('path');
const { exec } = require('child_process');

// Configuration (modify these if needed)
const NETWORK = 'testnet';
const GAS_BUDGET = '100000000';

// Path to sui binary (could be just 'sui' if it's in your PATH)
const SUI_BIN = 'sui';

// Path to Move.toml file
const MOVE_TOML_PATH = path.join(process.cwd(), 'Move.toml');

async function main() {
  try {
    console.log('Preparing to deploy Alpha4 contract to Sui ' + NETWORK);
    
    // Check if Move.toml exists
    if (!fs.existsSync(MOVE_TOML_PATH)) {
      console.error('Error: Move.toml not found. Are you in the correct directory?');
      process.exit(1);
    }
    
    // Step 1: Build the package
    console.log('\nBuilding package...');
    await runCommand(`${SUI_BIN} move build`);
    
    // Step 2: Publish to network
    console.log('\nPublishing package...');
    const publishOutput = await runCommand(
      `${SUI_BIN} client publish --gas-budget ${GAS_BUDGET}`
    );
    
    // Extract package ID and digest
    const packageIdMatch = publishOutput.match(/Published to ([a-f0-9x]+)/i);
    const digestMatch = publishOutput.match(/Transaction Digest: ([a-f0-9]+)/i);
    
    if (!packageIdMatch || !digestMatch) {
      console.error('Error: Could not extract package ID or transaction digest from output');
      console.log('Full output:');
      console.log(publishOutput);
      process.exit(1);
    }
    
    const packageId = packageIdMatch[1];
    const digest = digestMatch[1];
    
    console.log('\nDeployment successful!');
    console.log(`Package ID: ${packageId}`);
    console.log(`Transaction Digest: ${digest}`);
    console.log(`Explorer URL: https://explorer.sui.io/txblock/${digest}?network=${NETWORK}`);
    
    // Save deployment info
    const deploymentInfo = {
      network: NETWORK,
      packageId: packageId,
      transactionDigest: digest,
      timestamp: new Date().toISOString()
    };
    
    fs.writeFileSync(
      'deployment-info.json',
      JSON.stringify(deploymentInfo, null, 2)
    );
    
    console.log('\nDeployment info saved to deployment-info.json');
    
  } catch (error) {
    console.error('Deployment error:', error);
    process.exit(1);
  }
}

// Helper function to run a command and return the output
function runCommand(command) {
  return new Promise((resolve, reject) => {
    exec(command, { maxBuffer: 1024 * 1024 * 10 }, (error, stdout, stderr) => {
      if (error) {
        console.error('Command error:', stderr);
        reject(error);
        return;
      }
      resolve(stdout);
    });
  });
}

main();