// Global State
let adminMode = false;
let adminToken = '';
let currentPlatformFilter = 'all';
let searchFilter = '';
let sourcesData = [];
let debounceTimer = null;

// DOM Elements
const adminModeToggle = document.getElementById('adminModeToggle');
const platformSelect = document.getElementById('platform');
const sourceForm = document.getElementById('sourceForm');
const sourceNameInput = document.getElementById('sourceName');
const ingestUrlInput = document.getElementById('ingestUrl');
const inputByInput = document.getElementById('inputBy');
const countrySelect = document.getElementById('countrySelect');
const countryCustom = document.getElementById('countryCustom');
const topicSelect = document.getElementById('topicSelect');
const topicCustom = document.getElementById('topicCustom');
const tgCheckContainer = document.getElementById('tgCheckContainer');
const telegramPassed = document.getElementById('telegramPassed');
const gatingPassed = document.getElementById('gatingPassed');
const activityPassed = document.getElementById('activityPassed');
const formError = document.getElementById('formError');
const formSuccess = document.getElementById('formSuccess');
const submitBtn = document.getElementById('submitBtn');
const btnSpinner = document.getElementById('btnSpinner');
const urlWarning = document.getElementById('urlWarning');
const nameWarning = document.getElementById('nameWarning');

// Stats Elements
const statTotalActive = document.getElementById('statTotalActive');
const statVerifiedCount = document.getElementById('statVerifiedCount');
const statPlatforms = document.getElementById('statPlatforms');
const statCountries = document.getElementById('statCountries');
const trashStatCard = document.getElementById('trashStatCard');
const statTotalDeleted = document.getElementById('statTotalDeleted');

// Table and Toolbar Elements
const downloadCsvBtn = document.getElementById('downloadCsvBtn');
const downloadLogBtn = document.getElementById('downloadLogBtn');
const searchInput = document.getElementById('searchInput');
const filterBtns = document.querySelectorAll('.filter-btn');
const showDeletedToggle = document.getElementById('showDeletedToggle');
const tableBody = document.getElementById('tableBody');

// Admin Modal Elements
const adminModal = document.getElementById('adminModal');
const adminPasscode = document.getElementById('adminPasscode');
const adminModalError = document.getElementById('adminModalError');
const cancelAdminBtn = document.getElementById('cancelAdminBtn');
const confirmAdminBtn = document.getElementById('confirmAdminBtn');

// Login Elements
const loginOverlay = document.getElementById('loginOverlay');
const loginUsername = document.getElementById('loginUsername');
const loginPassword = document.getElementById('loginPassword');
const loginBtn = document.getElementById('loginBtn');
const loginError = document.getElementById('loginError');
const userInfoDisplay = document.getElementById('userInfoDisplay');
const currentUserLabel = document.getElementById('currentUserLabel');
const logoutBtn = document.getElementById('logoutBtn');

// Coordinator User Management Elements
const manageAuditorsBtn = document.getElementById('manageAuditorsBtn');
const adminAuditorsModal = document.getElementById('adminAuditorsModal');
const closeAuditorsModalBtn = document.getElementById('closeAuditorsModalBtn');
const createAuditorBtn = document.getElementById('createAuditorBtn');
const newAuditorUser = document.getElementById('newAuditorUser');
const newAuditorPass = document.getElementById('newAuditorPass');
const newAuditorError = document.getElementById('newAuditorError');
const newAuditorSuccess = document.getElementById('newAuditorSuccess');
const auditorsListBody = document.getElementById('auditorsListBody');

// --- Initialization ---
document.addEventListener('DOMContentLoaded', async () => {
    // 1. Enforce login / user mapping session
    checkUserSession();

    // 2. Restore Admin Token if saved in sessionStorage (for page refreshes)
    const savedToken = sessionStorage.getItem('admin_token');
    if (savedToken) {
        adminToken = savedToken;
        adminMode = true;
        adminModeToggle.checked = true;
        toggleAdminElements();
        await populateAuditorFilterSelect();
    }

    setupEventListeners();
    fetchStats();
    fetchSources();
});

// --- User Session Logic ---
function checkUserSession() {
    const user = localStorage.getItem('survey_auditor');
    if (!user) {
        // Enforce modal visibility
        loginOverlay.classList.remove('hidden');
        loginUsername.value = '';
        loginPassword.value = '';
        loginError.classList.add('hidden');
        loginUsername.focus();
        
        // Clear forms
        inputByInput.value = '';
        userInfoDisplay.classList.add('hidden');
    } else {
        // Hide login and map system fields
        loginOverlay.classList.add('hidden');
        inputByInput.value = user;
        
        // Show status header badge
        currentUserLabel.textContent = user;
        userInfoDisplay.classList.remove('hidden');
    }
}

async function handleLogin() {
    const username = loginUsername.value.trim();
    const password = loginPassword.value;
    
    if (!username || username.length < 2) {
        loginError.textContent = 'Please enter a valid username (min 2 characters).';
        loginError.classList.remove('hidden');
        return;
    }
    if (!password || password.length < 4) {
        loginError.textContent = 'Password must be at least 4 characters.';
        loginError.classList.remove('hidden');
        return;
    }
    
    try {
        loginBtn.disabled = true;
        loginBtn.textContent = 'Signing In...';
        
        const response = await fetch('/api/login', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ username, password })
        });
        const data = await response.json();
        
        if (!response.ok) {
            throw new Error(data.detail || 'Authentication failed. Please verify credentials.');
        }
        
        // Successfully authenticated
        localStorage.setItem('survey_auditor', data.username);
        checkUserSession();
        fetchStats();
        fetchSources();
    } catch (err) {
        loginError.textContent = err.message;
        loginError.classList.remove('hidden');
    } finally {
        loginBtn.disabled = false;
        loginBtn.textContent = 'Sign In';
    }
}

function handleLogout() {
    if (confirm('Are you sure you want to sign out? New source entries will require signing back in.')) {
        localStorage.removeItem('survey_auditor');
        checkUserSession();
    }
}

function getActiveFilterUser() {
    if (!adminMode) {
        return localStorage.getItem('survey_auditor') || '';
    } else {
        const select = document.getElementById('adminUserFilterSelect');
        const val = select ? select.value : 'all';
        return val === 'all' ? '' : val;
    }
}

async function populateAuditorFilterSelect() {
    const select = document.getElementById('adminUserFilterSelect');
    if (!select || !adminToken) return;
    
    const previousSelection = select.value;
    
    try {
        const response = await fetch('/api/admin/users', {
            headers: { 'X-Admin-Token': adminToken }
        });
        if (response.status === 401) {
            handleUnauthorized();
            return;
        }
        const users = await response.json();
        
        select.innerHTML = '<option value="all">All Auditors</option>';
        users.forEach(username => {
            const opt = document.createElement('option');
            opt.value = username;
            opt.textContent = username;
            select.appendChild(opt);
        });
        
        if (previousSelection && users.includes(previousSelection)) {
            select.value = previousSelection;
        } else {
            select.value = 'all';
        }
    } catch (err) {
        console.error('Error populating auditor filter select:', err);
    }
}

// --- Coordinator User Allocation (Admin Mode) ---
async function openAuditorsModal() {
    newAuditorUser.value = '';
    newAuditorPass.value = '';
    newAuditorError.classList.add('hidden');
    newAuditorSuccess.classList.add('hidden');
    adminAuditorsModal.classList.remove('hidden');
    await fetchAuditorsList();
}

function closeAuditorsModal() {
    adminAuditorsModal.classList.add('hidden');
}

async function fetchAuditorsList() {
    if (!adminToken) return;
    try {
        const response = await fetch('/api/admin/users', {
            headers: { 'X-Admin-Token': adminToken }
        });
        if (response.status === 401) {
            handleUnauthorized();
            return;
        }
        const users = await response.json();
        renderAuditorsList(users);
    } catch (err) {
        console.error('Error fetching auditor accounts:', err);
    }
}

function renderAuditorsList(users) {
    auditorsListBody.innerHTML = '';
    if (users.length === 0) {
        auditorsListBody.innerHTML = `<tr><td colspan="2" style="text-align: center; padding: 12px; color: var(--color-text-dim);">No active auditors found.</td></tr>`;
        return;
    }
    
    users.forEach(username => {
        const tr = document.createElement('tr');
        tr.style.borderBottom = '1px solid var(--color-border)';
        
        // Only allow revoking if it's not the primary coordinator seed (safety check)
        const isCoord = (username === 'ra_coordinator');
        const deleteButtonHTML = isCoord 
            ? `<span style="font-size: 11px; color: var(--color-text-dim);">System Account</span>`
            : `<button class="action-btn btn-delete" title="Revoke Account" onclick="revokeAuditorAccount('${username}')">
                   <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg>
               </button>`;
        
        tr.innerHTML = `
            <td style="padding: 8px 12px; font-weight: 500;">${username}</td>
            <td style="padding: 8px 12px; text-align: right;">${deleteButtonHTML}</td>
        `;
        auditorsListBody.appendChild(tr);
    });
}

async function allocateAuditorAccount() {
    newAuditorError.classList.add('hidden');
    newAuditorSuccess.classList.add('hidden');
    
    const username = newAuditorUser.value.trim();
    const password = newAuditorPass.value;
    
    if (!username || username.length < 2) {
        showAllocationError('Username must be at least 2 characters.');
        return;
    }
    if (!password || password.length < 4) {
        showAllocationError('Password must be at least 4 characters.');
        return;
    }
    
    try {
        createAuditorBtn.disabled = true;
        const response = await fetch('/api/admin/users', {
            method: 'POST',
            headers: { 
                'Content-Type': 'application/json',
                'X-Admin-Token': adminToken
            },
            body: JSON.stringify({ username, password })
        });
        const data = await response.json();
        
        if (!response.ok) {
            throw new Error(data.detail || 'Allocation failed.');
        }
        
        newAuditorSuccess.textContent = `Successfully allocated account for: ${data.username}`;
        newAuditorSuccess.classList.remove('hidden');
        newAuditorUser.value = '';
        newAuditorPass.value = '';
        await fetchAuditorsList();
        await populateAuditorFilterSelect();
    } catch (err) {
        showAllocationError(err.message);
    } finally {
        createAuditorBtn.disabled = false;
    }
}

function showAllocationError(msg) {
    newAuditorError.textContent = msg;
    newAuditorError.classList.remove('hidden');
}

window.revokeAuditorAccount = async function(username) {
    if (!adminToken) return;
    if (!confirm(`Are you sure you want to revoke/delete the auditor account for '${username}'?`)) return;
    
    try {
        const response = await fetch(`/api/admin/users/${username}`, {
            method: 'DELETE',
            headers: { 'X-Admin-Token': adminToken }
        });
        if (response.status === 401) {
            handleUnauthorized();
            return;
        }
        if (response.ok) {
            await fetchAuditorsList();
            await populateAuditorFilterSelect();
        } else {
            const data = await response.json();
            alert(data.detail || 'Failed to revoke account.');
        }
    } catch (err) {
        console.error('Error revoking account:', err);
    }
};

function setupEventListeners() {
    // User login actions
    loginBtn.addEventListener('click', handleLogin);
    loginUsername.addEventListener('keypress', (e) => {
        if (e.key === 'Enter') handleLogin();
    });
    loginPassword.addEventListener('keypress', (e) => {
        if (e.key === 'Enter') handleLogin();
    });
    logoutBtn.addEventListener('click', handleLogout);

    // Coordinator User Allocation Action Bindings
    manageAuditorsBtn.addEventListener('click', openAuditorsModal);
    closeAuditorsModalBtn.addEventListener('click', closeAuditorsModal);
    createAuditorBtn.addEventListener('click', allocateAuditorAccount);
    newAuditorPass.addEventListener('keypress', (e) => {
        if (e.key === 'Enter') allocateAuditorAccount();
    });

    // Admin Mode Switch
    adminModeToggle.addEventListener('change', (e) => {
        if (e.target.checked) {
            if (adminToken) {
                adminMode = true;
                toggleAdminElements();
                populateAuditorFilterSelect();
                fetchSources();
                fetchStats();
            } else {
                // Revert check, show passcode modal
                adminModeToggle.checked = false;
                openAdminModal();
            }
        } else {
            adminMode = false;
            adminToken = '';
            sessionStorage.removeItem('admin_token');
            toggleAdminElements();
            fetchSources();
            fetchStats();
        }
    });

    // Admin Passcode Modal Action Buttons
    cancelAdminBtn.addEventListener('click', closeAdminModal);
    confirmAdminBtn.addEventListener('click', verifyAdminPasscode);
    adminPasscode.addEventListener('keypress', (e) => {
        if (e.key === 'Enter') verifyAdminPasscode();
    });

    // Custom Country Dropdown Toggle
    countrySelect.addEventListener('change', () => {
        if (countrySelect.value === 'CUSTOM') {
            countryCustom.classList.remove('hidden');
            countryCustom.required = true;
        } else {
            countryCustom.classList.add('hidden');
            countryCustom.required = false;
            countryCustom.value = '';
        }
    });

    // Custom Topic Dropdown Toggle
    topicSelect.addEventListener('change', () => {
        if (topicSelect.value === 'CUSTOM') {
            topicCustom.classList.remove('hidden');
            topicCustom.required = true;
        } else {
            topicCustom.classList.add('hidden');
            topicCustom.required = false;
            topicCustom.value = '';
        }
    });

    // Platform-dependent Technical Audits
    platformSelect.addEventListener('change', () => {
        const platform = platformSelect.value;
        if (platform === 'telegram') {
            tgCheckContainer.classList.remove('hidden');
            telegramPassed.required = true;
            ingestUrlInput.placeholder = 'e.g. https://t.me/s/naijawatch';
            document.getElementById('urlHelp').textContent = 'For Telegram, standard public t.me/username link. No invite links (+).';
        } else {
            tgCheckContainer.classList.add('hidden');
            telegramPassed.required = false;
            telegramPassed.checked = false;
            if (platform === 'rss') {
                ingestUrlInput.placeholder = 'e.g. https://website.com/feed';
                document.getElementById('urlHelp').textContent = 'Direct RSS XML or Atom feed URL.';
            } else if (platform === 'newsletter') {
                ingestUrlInput.placeholder = 'e.g. https://newsletter.substack.com';
                document.getElementById('urlHelp').textContent = 'Substack or independent newsletter homepage URL.';
            } else {
                ingestUrlInput.placeholder = 'e.g. https://mastodon.social/@user';
                document.getElementById('urlHelp').textContent = 'Fediverse profile or channel URL (e.g. Mastodon).';
            }
        }
    });

    // Debounced Duplicate checking on keyup
    ingestUrlInput.addEventListener('input', () => {
        clearTimeout(debounceTimer);
        debounceTimer = setTimeout(checkDuplicates, 500);
    });

    sourceNameInput.addEventListener('input', () => {
        clearTimeout(debounceTimer);
        debounceTimer = setTimeout(checkDuplicates, 500);
    });

    // Form Submission
    sourceForm.addEventListener('submit', handleFormSubmit);

    // Search and Filter Listeners
    searchInput.addEventListener('input', (e) => {
        searchFilter = e.target.value.toLowerCase().trim();
        renderTable();
    });

    filterBtns.forEach(btn => {
        btn.addEventListener('click', () => {
            filterBtns.forEach(b => b.classList.remove('active'));
            btn.classList.add('active');
            currentPlatformFilter = btn.dataset.platform;
            renderTable();
        });
    });

    // Show Deleted checkbox toggle
    showDeletedToggle.addEventListener('change', () => {
        fetchSources();
    });

    // CSV Download
    downloadCsvBtn.addEventListener('click', () => {
        if (!adminToken) return;
        const user = getActiveFilterUser();
        let url = `/api/export?admin_token=${encodeURIComponent(adminToken)}`;
        if (user) {
            url += `&input_by=${encodeURIComponent(user)}`;
        }
        window.location.href = url;
    });

    // Log Download
    if (downloadLogBtn) {
        downloadLogBtn.addEventListener('click', () => {
            if (!adminToken) return;
            const url = `/api/admin/logs?admin_token=${encodeURIComponent(adminToken)}`;
            window.location.href = url;
        });
    }

    // Admin user filter select change listener
    const adminUserFilterSelect = document.getElementById('adminUserFilterSelect');
    if (adminUserFilterSelect) {
        adminUserFilterSelect.addEventListener('change', () => {
            fetchStats();
            fetchSources();
        });
    }
}

// --- Admin Modal Logic ---
function openAdminModal() {
    adminPasscode.value = '';
    adminModalError.classList.add('hidden');
    adminModal.classList.remove('hidden');
    adminPasscode.focus();
}

function closeAdminModal() {
    adminModal.classList.add('hidden');
    adminModeToggle.checked = adminMode;
}

async function verifyAdminPasscode() {
    const passcode = adminPasscode.value.trim();
    if (!passcode) {
        showAdminModalError('Please enter a passcode.');
        return;
    }

    try {
        const response = await fetch('/api/verify_admin', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ passcode })
        });
        const data = await response.json();

        if (!response.ok) {
            throw new Error(data.detail || 'Incorrect passcode.');
        }

        // Successfully verified
        adminToken = data.token;
        sessionStorage.setItem('admin_token', adminToken);
        adminMode = true;
        adminModeToggle.checked = true;
        closeAdminModal();
        toggleAdminElements();
        await populateAuditorFilterSelect();
        fetchSources();
        fetchStats();
    } catch (err) {
        showAdminModalError(err.message);
    }
}

function showAdminModalError(msg) {
    adminModalError.textContent = msg;
    adminModalError.classList.remove('hidden');
}

// --- Toggle Admin visibility ---
function toggleAdminElements() {
    const adminElements = document.querySelectorAll('.admin-only');
    adminElements.forEach(el => {
        if (adminMode) {
            el.classList.remove('hidden');
        } else {
            el.classList.add('hidden');
        }
    });
    
    // Hide ShowDeleted checkbox if Admin Mode turned off
    if (!adminMode) {
        showDeletedToggle.checked = false;
        trashStatCard.classList.add('hidden');
        adminAuditorsModal.classList.add('hidden'); // Close modal if open
    } else {
        trashStatCard.classList.remove('hidden');
    }
}

// --- Realtime Duplicate Checking ---
async function checkDuplicates() {
    const url = ingestUrlInput.value.trim();
    const name = sourceNameInput.value.trim();
    
    if (!url && !name) {
        urlWarning.classList.add('hidden');
        nameWarning.classList.add('hidden');
        return;
    }

    // Client-side quick check: prevent Telegram invite link early
    if (platformSelect.value === 'telegram' && url) {
        if (url.includes('+') || url.includes('#') || url.includes('joinchat')) {
            urlWarning.textContent = '❌ Private Telegram invite links containing "+", "#" or "joinchat" are prohibited.';
            urlWarning.classList.remove('hidden');
            return;
        }
    }

    try {
        let queryParams = new URLSearchParams();
        if (url) queryParams.append('url', url);
        if (name) queryParams.append('name', name);

        const response = await fetch(`/api/check_duplicate?${queryParams.toString()}`);
        const result = await response.json();

        if (result.is_duplicate) {
            if (result.url_match && url === result.url_match.ingest_url) {
                urlWarning.innerHTML = `⚠️ Duplicate Ingest URL! Exists under ID: <strong>${result.url_match.source_id}</strong> (${result.url_match.source_name})`;
                urlWarning.classList.remove('hidden');
            } else {
                urlWarning.classList.add('hidden');
            }

            if (result.name_match && name === result.name_match.source_name) {
                nameWarning.innerHTML = `⚠️ Duplicate Name! Exists under ID: <strong>${result.name_match.source_id}</strong>`;
                nameWarning.classList.remove('hidden');
            } else {
                nameWarning.classList.add('hidden');
            }
        } else {
            urlWarning.classList.add('hidden');
            nameWarning.classList.add('hidden');
        }
    } catch (err) {
        console.error('Error checking duplicate:', err);
    }
}

// --- Form Submission Handler ---
async function handleFormSubmit(e) {
    e.preventDefault();
    hideAlerts();

    const platform = platformSelect.value;
    const url = ingestUrlInput.value.trim();
    const auditor = inputByInput.value.trim();

    if (!auditor) {
        showError('No auditor logged in. Please sign in.');
        checkUserSession();
        return;
    }

    // 1. Double check validation for Telegram URL
    if (platform === 'telegram') {
        if (!url.includes('t.me/') && !url.includes('telegram.me/')) {
            showError('Telegram URL must contain t.me/ or telegram.me/');
            return;
        }
        if (url.includes('+') || url.includes('#') || url.includes('joinchat')) {
            showError('Private Telegram links are strictly prohibited.');
            return;
        }
    }

    // 2. Gather data
    const countryIso = countrySelect.value === 'CUSTOM' ? countryCustom.value.trim().toUpperCase() : countrySelect.value;
    const topicCode = topicSelect.value === 'CUSTOM' ? topicCustom.value.trim().toUpperCase() : topicSelect.value;

    if (!countryIso || countryIso.length < 2) {
        showError('Please specify a valid 2-letter Country ISO code.');
        return;
    }
    if (!topicCode || topicCode.length < 2) {
        showError('Please specify a valid Topic/Theme code.');
        return;
    }

    const payload = {
        source_name: sourceNameInput.value.trim(),
        platform: platform,
        ingest_url: url,
        primary_language: primaryLanguage.value.trim().toLowerCase(),
        languages_spoken: languagesSpoken.value.trim(),
        geographic_focus: geographicFocus.value.trim(),
        publisher_type: publisherType.value,
        input_by: auditor,
        gating_passed: gatingPassed.checked,
        activity_passed: activityPassed.checked,
        telegram_passed: platform === 'telegram' ? telegramPassed.checked : false,
        country_iso: countryIso,
        topic_code: topicCode
    };

    // 3. Send Request
    setLoading(true);
    try {
        const response = await fetch('/api/sources', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(payload)
        });

        const data = await response.json();
        
        if (!response.ok) {
            throw new Error(data.detail || 'An error occurred while saving the source.');
        }

        // Success
        showSuccess(`🎉 Source logged successfully with ID: <strong>${data.source_id}</strong>`);
        
        // Reset form and re-initialize session details
        sourceForm.reset();
        checkUserSession();
        
        // Reset custom fields
        countryCustom.classList.add('hidden');
        countryCustom.required = false;
        topicCustom.classList.add('hidden');
        topicCustom.required = false;
        tgCheckContainer.classList.remove('hidden'); // Default is telegram
        telegramPassed.required = true;
        
        // Refresh directory & counters
        fetchStats();
        fetchSources();
    } catch (err) {
        showError(err.message);
    } finally {
        setLoading(false);
    }
}

// --- Fetch stats and update widgets ---
async function fetchStats() {
    try {
        const user = getActiveFilterUser();
        const url = user ? `/api/stats?input_by=${encodeURIComponent(user)}` : '/api/stats';
        const response = await fetch(url);
        const stats = await response.json();

        statTotalActive.textContent = stats.total_active;
        statVerifiedCount.textContent = `${stats.total_verified} Verified`;
        statCountries.textContent = Object.keys(stats.by_country).length;
        statTotalDeleted.textContent = stats.total_deleted;

        // Platform breakdowns
        const tg = stats.by_platform.telegram || 0;
        const rss = stats.by_platform.rss || 0;
        const nl = stats.by_platform.newsletter || 0;
        const fed = stats.by_platform.fediverse || 0;
        statPlatforms.textContent = `TG: ${tg} | RSS: ${rss} | NL: ${nl} | FED: ${fed}`;
    } catch (err) {
        console.error('Error fetching stats:', err);
    }
}

// --- Fetch Ingested Sources ---
async function fetchSources() {
    try {
        const includeDeleted = adminMode && showDeletedToggle.checked;
        const user = getActiveFilterUser();
        let url = `/api/sources?include_deleted=${includeDeleted}`;
        if (user) {
            url += `&input_by=${encodeURIComponent(user)}`;
        }
        const response = await fetch(url);
        sourcesData = await response.json();
        renderTable();
    } catch (err) {
        console.error('Error fetching sources:', err);
        tableBody.innerHTML = `<tr><td colspan="8" class="text-center" style="color: var(--color-accent-red)">Failed to fetch sources data.</td></tr>`;
    }
}

// --- Render Table rows dynamically ---
function renderTable() {
    tableBody.innerHTML = '';
    
    // Apply filters locally
    const filtered = sourcesData.filter(source => {
        // Platform Filter
        if (currentPlatformFilter !== 'all' && source.platform !== currentPlatformFilter) {
            return false;
        }
        
        // Search Filter (checks ID, Name, Ingest URL, Language, publisher_type)
        if (searchFilter) {
            const idMatch = source.source_id.toLowerCase().includes(searchFilter);
            const nameMatch = source.source_name.toLowerCase().includes(searchFilter);
            const urlMatch = source.ingest_url.toLowerCase().includes(searchFilter);
            const langMatch = source.primary_language.toLowerCase().includes(searchFilter);
            const typeMatch = source.publisher_type.toLowerCase().includes(searchFilter);
            const auditorMatch = (source.input_by || '').toLowerCase().includes(searchFilter);
            if (!idMatch && !nameMatch && !urlMatch && !langMatch && !typeMatch && !auditorMatch) {
                return false;
            }
        }
        return true;
    });

    if (filtered.length === 0) {
        tableBody.innerHTML = `<tr><td colspan="${adminMode ? '8' : '7'}" class="text-center">No matching records found.</td></tr>`;
        return;
    }

    filtered.forEach(source => {
        const tr = document.createElement('tr');
        if (source.is_deleted) {
            tr.classList.add('row-deleted');
        }

        // Platform label badge styling
        let platformBadge = 'badge-blue';
        if (source.platform === 'rss') platformBadge = 'badge-green';
        if (source.platform === 'newsletter') platformBadge = 'badge-purple';
        if (source.platform === 'fediverse') platformBadge = 'badge-orange';

        // Verified status
        let statusBadgeHTML = '';
        if (source.is_deleted) {
            statusBadgeHTML = `<span class="stat-badge badge-red">Deleted</span>`;
        } else if (source.is_verified) {
            statusBadgeHTML = `<span class="stat-badge badge-green">Verified</span>`;
        } else {
            statusBadgeHTML = `<span class="stat-badge badge-amber">Pending</span>`;
        }

        // Publisher type string map
        const pubLabel = source.publisher_type.replace(/_/g, ' ');

        tr.innerHTML = `
            <td class="source-id-col">${source.source_id}</td>
            <td class="source-name-col">${source.source_name}<br><small style="color: var(--color-text-muted); font-size:10px;">By: ${source.input_by || 'unknown'}</small></td>
            <td><span class="stat-badge ${platformBadge}">${source.platform}</span></td>
            <td class="source-url-col"><a href="${source.ingest_url}" target="_blank">${source.ingest_url}</a></td>
            <td><span style="font-family: monospace;">${source.primary_language.toUpperCase()}</span></td>
            <td style="text-transform: capitalize;">${pubLabel}</td>
            <td>${statusBadgeHTML}</td>
        `;

        // Render Action Buttons if Admin Mode is enabled
        if (adminMode) {
            const actionsTd = document.createElement('td');
            actionsTd.className = 'action-buttons';
            
            if (source.is_deleted) {
                // Restore button
                actionsTd.innerHTML = `
                    <button class="action-btn btn-restore" title="Restore Source" onclick="restoreSource('${source.source_id}')">
                        <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M3 12a9 9 0 1 0 9-9 9.75 9.75 0 0 0-6.74 2.74L3 8"/><polyline points="3 3 3 8 8 8"/></svg>
                    </button>
                `;
            } else {
                // Verify toggle button + Delete button
                const verifyClass = source.is_verified ? 'btn-unverify' : 'btn-verify';
                const verifyTitle = source.is_verified ? 'Unverify Source' : 'Verify Source';
                const verifyIcon = source.is_verified 
                    ? `<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg>`
                    : `<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><polyline points="20 6 9 17 4 12"/></svg>`;

                actionsTd.innerHTML = `
                    <button class="action-btn ${verifyClass}" title="${verifyTitle}" onclick="toggleVerify('${source.source_id}', ${!source.is_verified})">
                        ${verifyIcon}
                    </button>
                    <button class="action-btn btn-delete" title="Delete Source" onclick="deleteSource('${source.source_id}')">
                        <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><polyline points="3 6 5 6 21 6"/><path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"/></svg>
                    </button>
                `;
            }
            tr.appendChild(actionsTd);
        }

        tableBody.appendChild(tr);
    });
}

// --- Admin action handlers ---
window.toggleVerify = async function(id, status) {
    if (!adminToken) return;
    try {
        const response = await fetch(`/api/sources/${id}/verify?verify=${status}`, {
            method: 'POST',
            headers: { 'X-Admin-Token': adminToken }
        });
        if (response.status === 401) {
            handleUnauthorized();
            return;
        }
        if (response.ok) {
            fetchStats();
            fetchSources();
        } else {
            console.error('Failed to update verification');
        }
    } catch (err) {
        console.error('Error toggling verify:', err);
    }
};

window.deleteSource = async function(id) {
    if (!adminToken) return;
    if (!confirm(`Are you sure you want to soft-delete source ${id}?`)) return;
    try {
        const response = await fetch(`/api/sources/${id}`, {
            method: 'DELETE',
            headers: { 'X-Admin-Token': adminToken }
        });
        if (response.status === 401) {
            handleUnauthorized();
            return;
        }
        if (response.ok) {
            fetchStats();
            fetchSources();
        } else {
            console.error('Failed to soft-delete source');
        }
    } catch (err) {
        console.error('Error soft-deleting:', err);
    }
};

window.restoreSource = async function(id) {
    if (!adminToken) return;
    try {
        const response = await fetch(`/api/sources/${id}/restore`, {
            method: 'POST',
            headers: { 'X-Admin-Token': adminToken }
        });
        if (response.status === 401) {
            handleUnauthorized();
            return;
        }
        if (response.ok) {
            fetchStats();
            fetchSources();
        } else {
            console.error('Failed to restore source');
        }
    } catch (err) {
        console.error('Error restoring:', err);
    }
};

function handleUnauthorized() {
    alert('Session expired or unauthorized. Admin access cleared.');
    adminToken = '';
    sessionStorage.removeItem('admin_token');
    adminMode = false;
    adminModeToggle.checked = false;
    toggleAdminElements();
    fetchSources();
    fetchStats();
}

// --- Helper Functions ---
function setLoading(loading) {
    if (loading) {
        submitBtn.disabled = true;
        btnSpinner.classList.remove('hidden');
    } else {
        submitBtn.disabled = false;
        btnSpinner.classList.add('hidden');
    }
}

function showError(msg) {
    formError.innerHTML = msg;
    formError.classList.remove('hidden');
}

function showSuccess(msg) {
    formSuccess.innerHTML = msg;
    formSuccess.classList.remove('hidden');
}

function hideAlerts() {
    formError.classList.add('hidden');
    formSuccess.classList.add('hidden');
}
