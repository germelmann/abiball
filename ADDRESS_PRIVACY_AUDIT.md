# Address Privacy Audit - Security Fix

## Overview
This document describes the changes made to ensure that user addresses are only accessible through the designated `/api/get_user_address` endpoint with proper access logging.

## Problem Statement
Previously, user addresses were exposed through multiple API endpoints without proper access logging:
- `/api/all_ticket_orders` - returned address for all ticket orders
- `/api/get_ticket_order` - returned address for specific orders

This violated the privacy requirement that only `/api/get_user_address` should send user addresses (with logging).

## Changes Made

### 1. Backend API Modifications (`src/ruby/include/tickets.rb`)

#### `/api/all_ticket_orders` (POST)
**Before:**
```ruby
RETURN u.name AS user_name,
       u.email AS user_email,
       u.address AS user_address,  # ❌ Address exposed
       u.phone AS user_phone,
       ...
```

**After:**
```ruby
RETURN u.name AS user_name,
       u.email AS user_email,
       u.username AS user_username,  # ✅ Added for profile linking
       u.phone AS user_phone,
       ...
```

#### `/api/get_ticket_order` (POST)
**Before:**
```ruby
RETURN u.name AS user_name,
       u.email AS user_email,
       u.address AS user_address,  # ❌ Address exposed
       u.phone AS user_phone,
       ...
```

**After:**
```ruby
RETURN u.name AS user_name,
       u.email AS user_email,
       u.username AS user_username,  # ✅ Added for profile linking
       u.phone AS user_phone,
       ...
```

### 2. Frontend UI Updates

#### `src/static/order_detail.html`
**Before:**
- Displayed address in a textarea field
- Address was directly visible in order details

**After:**
- Replaced with a "Benutzerprofil anzeigen" (View User Profile) button
- Links to `/user_detail?username=<username>`
- Shows helper text: "Adresse und weitere Details im Benutzerprofil"

#### `src/static/order_management.html`
**Before:**
- Modal contained address textarea field
- Address was sent in update API calls

**After:**
- Replaced with "Benutzerprofil anzeigen" link
- Removed user_address from update API payload
- Modal now links to user profile for address access

### 3. Update API Behavior
The `/api/update_ticket_order` endpoint still accepts `user_address` as an optional parameter for backward compatibility, but:
- Frontend no longer sends this parameter
- Uses COALESCE to preserve existing values if not provided
- Does not return the address in response

## Security Verification

### ✅ Endpoints that CORRECTLY handle addresses:

#### 1. `/api/get_user_address` (POST)
- **Purpose**: Designated endpoint for viewing user addresses
- **Permission**: Requires "view_users" permission
- **Logging**: ✅ Creates AddressAccessLog entry
- **Security**: Proper access control and audit trail

#### 2. `/api/get_profile_data` (POST)
- **Purpose**: User viewing their own profile
- **Permission**: Requires authenticated user
- **Security**: ✅ Uses `@session_user[:email]` - only returns own data
- **Acceptable**: Users should see their own address

#### 3. `/api/generate_order_pdf/:order_id` (GET)
- **Purpose**: Generate order confirmation PDF
- **Permission**: Order owner OR admin with "view_users"
- **Security**: ✅ Checks `@session_user[:email] == order_user_email`
- **Acceptable**: Users need their address on order confirmations

### ❌ Endpoints FIXED to remove address leakage:

#### 4. `/api/all_ticket_orders` (POST)
- **Before**: ❌ Returned addresses for all orders
- **After**: ✅ Returns username for profile linking
- **Impact**: Admins now click through to user profile to see address (with logging)

#### 5. `/api/get_ticket_order` (POST)
- **Before**: ❌ Returned address for specific order
- **After**: ✅ Returns username for profile linking
- **Impact**: Admins now click through to user profile to see address (with logging)

## User Experience Impact

### For Regular Users
- **No change**: Users can still view their own address via profile
- **No change**: Order PDFs still include address for confirmation

### For Admins/Support Staff
- **Minor workflow change**: Instead of seeing address directly in order view:
  1. Click "Benutzerprofil anzeigen" button in order details
  2. Redirects to user detail page
  3. Click "Adresse anzeigen" button on user profile
  4. Address is displayed and access is logged

### Benefits
- All address access is now properly logged
- Clear audit trail for compliance
- Follows principle of least privilege
- Minimal UI changes required

## Testing Recommendations

1. **Test Order Management Flow:**
   - View order in `/order_management`
   - Verify "Benutzerprofil anzeigen" link appears
   - Click link and verify redirect to user profile works
   - Verify address is NOT displayed directly

2. **Test Order Detail Page:**
   - Navigate to `/order_detail/<order_id>`
   - Verify "Benutzerprofil anzeigen" button appears
   - Click button and verify navigation to user profile
   - Verify phone number still displays correctly

3. **Test Address Access Logging:**
   - Go to user detail page
   - Click "Adresse anzeigen" button
   - Verify address is displayed
   - Check that access was logged in database (AddressAccessLog)

4. **Test User Profile:**
   - Log in as regular user
   - View own profile via `/api/get_profile_data`
   - Verify own address is still visible

5. **Test Order PDF:**
   - Generate order confirmation PDF
   - Verify address is included in PDF for own orders
   - Verify PDF generation fails for other users' orders (unless admin)

## Database Impact

**No database migrations required.**

The changes only affect:
- API response payload (removed field)
- Frontend display logic
- No schema changes needed

## Rollback Plan

If issues are discovered:

1. Revert `src/ruby/include/tickets.rb`:
   - Add back `u.address AS user_address` in both queries
   - Remove `u.username AS user_username` if not needed

2. Revert `src/static/order_detail.html`:
   - Replace button with textarea
   - Restore `$('#user_address_input').val(order.user_address || '')`

3. Revert `src/static/order_management.html`:
   - Replace button with textarea
   - Restore `user_address: $('#user_address_input').val()` in saveOrderChanges

## Compliance Notes

This change improves compliance with:
- **GDPR**: Minimizes unnecessary exposure of personal data
- **Audit Requirements**: All address access is now logged
- **Security Best Practices**: Implements least privilege principle
- **Privacy by Design**: Data access requires explicit action with logging

## Related Files

- `src/ruby/include/tickets.rb` - API endpoint definitions
- `src/ruby/include/users.rb` - User address endpoint with logging
- `src/static/order_detail.html` - Order detail page UI
- `src/static/order_management.html` - Order management UI
- `src/static/user.html` - User profile with address access logging
- `EVENT_CONTEXT_FEATURE.md` - Original address logging feature documentation
