import { fetchProducts } from './products.js';
// Account management
let accountId = localStorage.getItem('accountId');
let accountStatus = null;

// DOM elements
const createAccountForm = document.getElementById('create-account-form');
const accountStatusEl = document.getElementById('account-status');
const addProductBtn = document.getElementById("add-product");
const productForm = document.getElementById("create-product-form");
const productsSection = document.getElementById('products-section');
const productsList = document.getElementById('products-list');
const toggleProductsBtn = document.getElementById('toggle-products');
const storefrontsEl = document.getElementById('storefronts');
const subscriptionSectionEl = document.getElementById('subscription-section');

// Initialize the page
function init() {
    if (accountId) {
        fetchAccountStatus();
        updateStorefronts();
        checkSubscriptionStatus();
    }

    setupEventListeners();
}

function setupEventListeners() {
    // Create account form
    document.getElementById('create-account-form').addEventListener('submit', async (e) => {
        e.preventDefault();
        const email = document.getElementById('email').value;
        await createConnectAccount(email);
    });

    // Create product form
    document.getElementById('create-product-form').addEventListener('submit', async (e) => {
        e.preventDefault();
        const productName = document.getElementById('productName').value;
        const productDescription = document.getElementById('productDescription').value;
        const productPrice = parseInt(document.getElementById('productPrice').value);

        await createProduct(productName, productDescription, productPrice);
        // Close the product form by toggling its visibility and updating the button text
        productForm.classList.add("hidden");
        addProductBtn.textContent = "Add New Product";
        fetchProducts();
    });

    // Toggle products visibility
    toggleProductsBtn.addEventListener('click', () => {
        const isHidden = productsList.classList.contains('hidden');
        productsList.classList.toggle('hidden');
        toggleProductsBtn.textContent = isHidden ? 'Hide Products' : 'Show Products';

        if (isHidden) {
            fetchProducts();
        }
    });

    addProductBtn.addEventListener("click", () => {
        productForm.classList.toggle("hidden");
        addProductBtn.textContent = productForm.classList.contains("hidden")
            ? "Add New Product"
            : "Cancel";
    });
}

async function fetchAccountStatus() {
    if (!accountId) return;

    try {
        const response = await fetch(`/api/account-status/${accountId}`);
        if (!response.ok) {
            logout();
            throw new Error('Failed to fetch account status');
        }
        accountStatus = await response.json();
        renderAccountStatus();

        // Show product form if account is ready
        if (accountStatus.chargesEnabled) {
            addProductBtn.classList.remove("hidden");
            productsSection.classList.remove('hidden');
            createAccountForm.classList.add("hidden");
        }
    } catch (error) {
        console.error('Error fetching account status:', error);
    }
}

function renderAccountStatus() {
    if (!accountStatus) return;

    const statusColor = accountStatus.chargesEnabled ? 'green' : 'orange';
    const statusText = accountStatus.chargesEnabled ? 'Active' : 'Pending';

    accountStatusEl.innerHTML = `
    <div class="account-status">
      <div class="status-header">
        <h3>Account Status: <span style="color: ${statusColor}">${statusText}</span></h3>
      </div>
      <div class="status-details">
        <div class="status-item">
          <span>Account ID:</span>
          <span>${accountStatus.id}</span>
        </div>
        <div class="status-item">
          <span>Payouts enabled:</span>
          <span>${accountStatus.payoutsEnabled ? '✅' : '❌'}</span>
        </div>
        <div class="status-item">
          <span>Charges enabled:</span>
          <span>${accountStatus.chargesEnabled ? '✅' : '❌'}</span>
        </div>
        <div class="status-item">
          <span>Details submitted:</span>
          <span>${accountStatus.detailsSubmitted ? '✅' : '❌'}</span>
        </div>
      </div>
      ${needsOnboarding() ?
        `<button id="start-onboarding" class="button margin-bottom-10">Onboard to collect payments</button>` : ''}
      <button id="logout" class="button">Log out</button>
    </div>
  `;

    // Add event listeners to the new buttons
    if (needsOnboarding()) {
        document
            .getElementById('start-onboarding')
            .addEventListener('click', startOnboarding);
    }

    document.getElementById('logout').addEventListener('click', logout);
}

function needsOnboarding() {
    return !accountStatus?.chargesEnabled && !accountStatus?.detailsSubmitted;
}

function logout() {
    accountId = null;
    accountStatus = null;
    localStorage.removeItem('accountId');

    // Reset UI
    accountStatusEl.innerHTML = '';
    addProductBtn.classList.add("hidden");
    productForm.classList.add('hidden');
    productsSection.classList.add('hidden');
    productsList.classList.add('hidden');
    toggleProductsBtn.textContent = 'Show Products';
    createAccountForm.classList.remove("hidden");
}

function updateStorefronts() {
    storefrontsEl.innerHTML = `
    <a href="storefront.html?accountId=${accountId}" class="button storefront-link">
      View Storefront (${accountId})
    </a>
  `
}

// Start polling for account status
let statusInterval;
function startStatusPolling() {
    clearInterval(statusInterval);
    statusInterval = setInterval(fetchAccountStatus, 5000);
}

// Initialize when DOM is ready
document.addEventListener('DOMContentLoaded', () => {
    init();
    if (accountId) {
        startStatusPolling();
    }
});

// Clean up on page unload
window.addEventListener('beforeunload', () => {
    clearInterval(statusInterval);
});

async function createConnectAccount(email) {
    try {
        const response = await fetch("/api/create-connect-account", {
            method: "POST",
            headers: {
                "Content-Type": "application/json",
            },
            body: JSON.stringify({ email }),
        });

        if (!response.ok) {
            throw new Error("Failed to create connect account");
        }

        const { accountId: newAccountId } = await response.json();
        accountId = newAccountId;
        localStorage.setItem("accountId", accountId);
        await fetchAccountStatus();
        updateStorefronts();
        startStatusPolling();
    } catch (error) {
        console.error("Error creating connect account", error);
    }
}

async function startOnboarding() {
    try {
        const response = await fetch("/api/create-account-link", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ accountId }),
        });

        const { url } = await response.json();
        window.location.href = url;
    } catch (error) {
        console.error("Error starting onboarding:", error);
    }
}

async function createProduct(productName, productDescription, productPrice) {
    if (!accountId) return;

    try {

        const response = await fetch("/api/create-product", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({
                productName,
                productDescription,
                productPrice,
                accountId,
            }),
        });

        if (!response.ok) {
            throw new Error("Failed to create product");
        }

        // Clear the form
        document.getElementById("productName").value = "";
        document.getElementById("productDescription").value = "";
        document.getElementById("productPrice").value = "1000";
    } catch (error) {
        console.error("Error creating product:", error);
    }
}

// Subscription to platform functionality
function checkSubscriptionStatus() {
    // Check URL parameters for subscription status
    const urlParams = new URLSearchParams(window.location.search);
    const success = urlParams.get('success');
    const canceled = urlParams.get('canceled');
    const sessionId = urlParams.get('session_id');

    if (success) {
        renderSubscriptionSuccess(sessionId);
    } else if (canceled) {
        renderSubscriptionCanceled();
    } else {
        renderSubscriptionButton();
    }
}

function renderSubscriptionButton() {
    if (!subscriptionSectionEl) return;

    subscriptionSectionEl.innerHTML = `
    <button id="subscribe-btn" class="button">
      Subscribe to platform
    </button>
  `;

    document.getElementById('subscribe-btn').addEventListener('click', handleSubscribe);
}

function renderSubscriptionSuccess(sessionId) {
    if (!subscriptionSectionEl) return;

    subscriptionSectionEl.innerHTML = `
    <section>
      <div class="product Box-root">
        <div class="description Box-root">
          <h3>Subscription to Starter Plan successful!</h3>
        </div>
      </div>
      <form action="/api/create-portal-session" method="POST">
        <input type="hidden" name="session_id" value="${sessionId}" />
        <button id="checkout-and-portal-button" class="button" type="submit">
          Manage your billing information
        </button>
      </form>
    </section>
  `;
}

function renderSubscriptionCanceled() {
    if (!subscriptionSectionEl) return;

    subscriptionSectionEl.innerHTML = `
    <section>
      <p>Order canceled -- continue to shop around and checkout when you're ready.</p>
    </section>
    <button id="subscribe-btn" class="button">
      Subscribe to platform
    </button>
  `;

    document.getElementById('subscribe-btn').addEventListener('click', handleSubscribe);
}

async function handleSubscribe() {
    if (!accountId) return;

    try {
        const response = await fetch('/api/subscribe-to-platform', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ accountId }),
        });

        if (!response.ok) {
            console.error('Subscription failed');
            return;
        }

        const data = await response.json();
        const checkoutSessionUrl = data.url;
        window.location.href = checkoutSessionUrl;
    } catch (error) {
        console.error('Error subscribing to platform:', error);
    }
}

