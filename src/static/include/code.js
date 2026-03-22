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

// Order status translations
function getOrderStatusText(status) {
    const statusMap = {
        'paid': 'Bezahlt',
        'partially_paid': 'Teilweise bezahlt',
        'pending': 'Ausstehend',
        'pending_payment': 'Zahlung ausstehend',
        'offline_payment': 'Barzahlung',
        'cancelled': 'Storniert',
        'cancelled_by_user': 'Storniert durch Käufer',
        'in_review': 'Manuelle Prüfung',
        'on_hold': 'Pausiert',
        'issue': 'Problem/Fehler',
        'contact_required': 'Kontakt erforderlich'
    };
    return statusMap[status] || status;
}

function getOrderStatusBadgeClass(status) {
    const classMap = {
        'paid': 'bg-success',
        'partially_paid': 'bg-info',
        'pending': 'bg-warning text-dark',
        'pending_payment': 'bg-info',
        'offline_payment': 'bg-info',
        'cancelled': 'bg-danger',
        'cancelled_by_user': 'bg-danger',
        'in_review': 'bg-primary',
        'on_hold': 'bg-secondary',
        'issue': 'bg-danger',
        'contact_required': 'bg-warning text-dark'
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

// Helper function for escaping HTML (if not already defined)
if (typeof escapeHtml === 'undefined') {
    function escapeHtml(text) {
        if (text == null) return '';
        const div = document.createElement('div');
        div.textContent = text;
        return div.innerHTML;
    }
}
