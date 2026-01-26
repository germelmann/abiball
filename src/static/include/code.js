function show_error_message(message) {
    var div = $('<div>').css('text-align', 'center').css('padding', '15px').addClass('bg-light text-danger').html(message);
    $('.api_messages').empty();
    let button = $("<button class='text-stone-400 btn pull-right form-control' style='width: unset; margin: 8px;' ><i class='bi bi-times'></i></button>");
    $('.api_messages').append(button).append(div).show();
    button.on('click', function(e) { e.preventDefault(); $('.api_messages').hide(); });
}

function show_success_message(message) {
    var div = $('<div>').css('text-align', 'center').css('padding', '15px').addClass('bg-light text-success').html(message);
    $('.api_messages').empty();
    $('.api_messages').append(div).show();
}

function api_call(url, data, callback, options) {
    if (typeof (options) === 'undefined')
        options = {};

    if (typeof (window.please_wait_timeout) !== 'undefined')
        clearTimeout(window.please_wait_timeout);

    if (options.no_please_wait !== true) {
        // show 'please wait' message after 500 ms
        (function () {
            window.please_wait_timeout = setTimeout(function () {
                var div = $('<div>').css('text-align', 'center').css('padding', '15px').addClass('text-muted').html("<i class='bi bi-cog fa-spin'></i>&nbsp;&nbsp;Einen Moment bitte...");
                $('.api_messages').empty().show();
                $('.api_messages').append(div);
            }, 500);
        })();
    }

    if (typeof(data) !== 'string')
        data = JSON.stringify(data);

    let conf = {
        url: url,
        data: data,
        contentType: 'application/json',
        dataType: 'json',
    };
    if (options.dataType)
        conf.dataType = options.dataType;
    if (options.contentType)
        conf.contentType = options.contentType;

    if (typeof (options.headers) !== 'undefined') {
        conf.beforeSend = function (xhr) {
            for (let key in options.headers)
                xhr.setRequestHeader(key, options.headers[key]);
        };
    }
    let jqxhr = null;
    if (options.method === 'GET')
        jqxhr = jQuery.get(conf);
    else
        jqxhr = jQuery.post(conf);

    jqxhr.done(function (data) {
        clearTimeout(window.please_wait_timeout);
        $('.api_messages').empty().hide();
        if (typeof (callback) !== 'undefined') {
            callback(data);
        }
    });

    jqxhr.fail(function (http) {
        clearTimeout(window.please_wait_timeout);
        $('.api_messages').empty();
        show_error_message('Bei der Bearbeitung der Anfrage ist ein Fehler aufgetreten.');
        if (typeof (callback) !== 'undefined') {
            var error_message = 'unknown_error';
            try {
                error_message = JSON.parse(http.responseText)['error'];
            } catch (err) {
            }
            console.log(error_message);
            callback({ success: false, error: error_message });
        }
    });
}

function perform_logout() {
    api_call('/api/logout', {}, function (data) {
        if (data.success)
            window.location.href = '/';
    });
}

function isValidISBN10(isbn) {
    if (!/^\d{9}[\dXx]$/.test(isbn)) return false;
    let sum = 0;
    for (let i = 0; i < 9; i++) {
        sum += (i + 1) * parseInt(isbn.charAt(i), 10);
    }
    let check = isbn.charAt(9).toUpperCase() === "X" ? 10 : parseInt(isbn.charAt(9), 10);
    sum += 10 * check;
    return sum % 11 === 0;
}

function isValidISBN13(isbn) {
    if (!/^\d{13}$/.test(isbn)) return false;
    let sum = 0;
    for (let i = 0; i < 12; i++) {
        let digit = parseInt(isbn.charAt(i), 10);
        sum += (i % 2 === 0) ? digit : digit * 3;
    }
    let check = (10 - (sum % 10)) % 10;
    return check === parseInt(isbn.charAt(12), 10);
}

function validateISBN(isbn) {
    if (!isbn) return true;
    isbn = isbn.replace(/[-\s]/g, "");
    return isValidISBN10(isbn) || isValidISBN13(isbn);
}

// Order status translations
function getOrderStatusText(status) {
    const statusMap = {
        'paid': 'Bezahlt',
        'pending': 'Ausstehend',
        'pending_payment': 'Zahlung ausstehend',
        'cancelled': 'Storniert',
        'cancelled_by_user': 'Storniert durch Käufer'
    };
    return statusMap[status] || status;
}

function getOrderStatusBadgeClass(status) {
    const classMap = {
        'paid': 'bg-success',
        'pending': 'bg-warning',
        'pending_payment': 'bg-info',
        'cancelled': 'bg-danger',
        'cancelled_by_user': 'bg-danger'
    };
    return classMap[status] || 'bg-secondary';
}

function getOrderStatusBadge(status) {
    const text = getOrderStatusText(status);
    const badgeClass = getOrderStatusBadgeClass(status);
    return `<span class="badge ${badgeClass}">${text}</span>`;
}

/**
 * User Search Component
 * A reusable component for searching and selecting users
 * 
 * @param {Object} options - Configuration options
 * @param {string} options.containerId - ID of the container element to render the component
 * @param {boolean} options.multiSelect - Enable multi-select mode (default: false)
 * @param {Array<string>} options.filterPermissions - Only include users with these permissions (empty = all users)
 * @param {Array<string>} options.excludeUsernames - Exclude these usernames from results
 * @param {string} options.placeholder - Placeholder text for search input
 * @param {function} options.onSelect - Callback when user(s) selected: onSelect(users) where users is array of {username, name, email}
 * @param {function} options.onChange - Callback when selection changes: onChange(users)
 * @returns {Object} - Component instance with methods: getSelected(), clear(), setUsers(users)
 */
function createUserSearchComponent(options) {
    const config = {
        containerId: options.containerId,
        multiSelect: options.multiSelect || false,
        filterPermissions: options.filterPermissions || [],
        excludeUsernames: options.excludeUsernames || [],
        placeholder: options.placeholder || 'Benutzer suchen...',
        onSelect: options.onSelect || function() {},
        onChange: options.onChange || function() {}
    };
    
    let allUsers = [];
    let selectedUsers = [];
    let searchTimeout = null;
    
    const container = $('#' + config.containerId);
    if (container.length === 0) {
        console.error('User search component: Container not found:', config.containerId);
        return null;
    }
    
    // Build the component HTML
    const componentHtml = `
        <div class="user-search-component">
            <div class="input-group mb-2">
                <input type="text" class="form-control user-search-input" placeholder="${config.placeholder}">
                <button class="btn btn-outline-secondary user-search-clear" type="button" style="display:none;">
                    <i class="bi bi-x"></i>
                </button>
            </div>
            <div class="user-search-results list-group" style="max-height: 300px; overflow-y: auto; display: none;"></div>
            <div class="user-search-selected mt-2"></div>
        </div>
    `;
    
    container.html(componentHtml);
    
    const searchInput = container.find('.user-search-input');
    const resultsDiv = container.find('.user-search-results');
    const selectedDiv = container.find('.user-search-selected');
    const clearBtn = container.find('.user-search-clear');
    
    // Load users based on filters
    function loadUsers() {
        let endpoint = '/api/get_all_users';
        let requestData = {};
        
        api_call(endpoint, requestData, function(response) {
            if (response.success) {
                allUsers = response.users || [];
                
                // Apply permission filter if specified
                if (config.filterPermissions.length > 0) {
                    allUsers = allUsers.filter(function(user) {
                        if (!user.permissions) return false;
                        return config.filterPermissions.some(function(perm) {
                            return user.permissions.includes(perm);
                        });
                    });
                }
                
                // Apply exclusions
                if (config.excludeUsernames.length > 0) {
                    allUsers = allUsers.filter(function(user) {
                        return !config.excludeUsernames.includes(user.username);
                    });
                }
            } else {
                // Permission denied or error - show message in results
                allUsers = [];
                resultsDiv.html('<div class="list-group-item text-muted"><em>Keine Berechtigung zum Anzeigen von Benutzern</em></div>');
            }
        }, { no_please_wait: true });
    }
    
    // Filter and display search results
    function showResults(query) {
        resultsDiv.empty();
        
        if (!query || query.length < 2) {
            resultsDiv.hide();
            return;
        }
        
        const lowerQuery = query.toLowerCase();
        const filtered = allUsers.filter(function(user) {
            // Don't show already selected users
            const isSelected = selectedUsers.some(function(u) {
                return u.username === user.username;
            });
            if (isSelected) return false;
            
            // Match against username, name, or email
            return (user.username && user.username.toLowerCase().includes(lowerQuery)) ||
                   (user.name && user.name.toLowerCase().includes(lowerQuery)) ||
                   (user.email && user.email.toLowerCase().includes(lowerQuery));
        });
        
        if (filtered.length === 0) {
            resultsDiv.html('<div class="list-group-item text-muted"><em>Keine Ergebnisse</em></div>');
            resultsDiv.show();
            return;
        }
        
        // Show up to 10 results
        filtered.slice(0, 10).forEach(function(user) {
            const item = $('<a href="#" class="list-group-item list-group-item-action">')
                .html(`
                    <div class="d-flex w-100 justify-content-between">
                        <h6 class="mb-1">${escapeHtml(user.name || user.username)}</h6>
                        <small class="text-muted">${escapeHtml(user.username)}</small>
                    </div>
                    ${user.email ? `<small class="text-muted">${escapeHtml(user.email)}</small>` : ''}
                `)
                .on('click', function(e) {
                    e.preventDefault();
                    selectUser(user);
                });
            resultsDiv.append(item);
        });
        
        resultsDiv.show();
    }
    
    // Select a user
    function selectUser(user) {
        if (config.multiSelect) {
            selectedUsers.push(user);
        } else {
            selectedUsers = [user];
        }
        
        searchInput.val('');
        resultsDiv.hide();
        displaySelected();
        config.onSelect(config.multiSelect ? selectedUsers : selectedUsers[0]);
        config.onChange(selectedUsers);
        
        if (!config.multiSelect) {
            searchInput.prop('disabled', true);
            clearBtn.show();
        }
    }
    
    // Remove a user from selection
    function removeUser(username) {
        selectedUsers = selectedUsers.filter(function(u) {
            return u.username !== username;
        });
        
        displaySelected();
        config.onChange(selectedUsers);
        
        if (!config.multiSelect) {
            searchInput.prop('disabled', false);
            clearBtn.hide();
        }
    }
    
    // Display selected users
    function displaySelected() {
        selectedDiv.empty();
        
        if (selectedUsers.length === 0) {
            return;
        }
        
        const badgeContainer = $('<div class="d-flex flex-wrap gap-2">');
        
        selectedUsers.forEach(function(user) {
            const badge = $('<span class="badge bg-primary">')
                .text(user.name || user.username);
            
            const removeBtn = $('<i class="bi bi-x-circle ms-1" style="cursor:pointer;"></i>')
                .on('click', function() {
                    removeUser(user.username);
                });
            
            badge.append(removeBtn);
            badgeContainer.append(badge);
        });
        
        selectedDiv.append(badgeContainer);
    }
    
    // Event handlers
    searchInput.on('input', function() {
        const query = $(this).val();
        
        if (searchTimeout) {
            clearTimeout(searchTimeout);
        }
        
        searchTimeout = setTimeout(function() {
            showResults(query);
        }, 300);
    });
    
    searchInput.on('focus', function() {
        if ($(this).val().length >= 2) {
            showResults($(this).val());
        }
    });
    
    // Close results when clicking outside
    $(document).on('click', function(e) {
        if (!container.find(e.target).length) {
            resultsDiv.hide();
        }
    });
    
    clearBtn.on('click', function() {
        selectedUsers = [];
        searchInput.prop('disabled', false).val('');
        clearBtn.hide();
        displaySelected();
        config.onChange(selectedUsers);
    });
    
    // Initialize
    loadUsers();
    
    // Public API
    return {
        getSelected: function() {
            return config.multiSelect ? selectedUsers : (selectedUsers[0] || null);
        },
        clear: function() {
            selectedUsers = [];
            searchInput.prop('disabled', false).val('');
            clearBtn.hide();
            resultsDiv.hide();
            displaySelected();
        },
        setUsers: function(users) {
            selectedUsers = Array.isArray(users) ? users : [users];
            displaySelected();
            if (!config.multiSelect && selectedUsers.length > 0) {
                searchInput.prop('disabled', true);
                clearBtn.show();
            }
        },
        reload: function(newOptions) {
            if (newOptions) {
                if (newOptions.filterPermissions !== undefined) config.filterPermissions = newOptions.filterPermissions;
                if (newOptions.excludeUsernames !== undefined) config.excludeUsernames = newOptions.excludeUsernames;
            }
            loadUsers();
        }
    };
}

// Helper function for escaping HTML (if not already defined)
if (typeof escapeHtml === 'undefined') {
    function escapeHtml(text) {
        if (text == null) return '';
        const div = document.createElement('div');
        div.textContent = text;
        return div.innerHTML;
    }
}
