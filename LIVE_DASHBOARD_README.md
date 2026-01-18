# Real-time Dashboard and PWA Features

## Overview

This document describes the real-time dashboard and Progressive Web App (PWA) features added to the Abiball ticket system.

## Features

### 1. Real-time Dashboard

The live dashboard provides real-time statistics and monitoring for events.

**Access:** Navigate to `/live_dashboard.html` (requires `manage_orders` permission)

**Features:**
- **Live Statistics Cards:**
  - Total tickets sold
  - Number of checked-in attendees
  - Number of not-yet-checked-in attendees
  - Scans in the last minute

- **Arrival Distribution Chart:**
  - Shows hourly arrival pattern over the last 12 hours
  - Automatically updates every 5 seconds

- **Attendee Lists:**
  - **Present:** List of all checked-in attendees with check-in times
  - **Missing:** List of attendees who haven't checked in yet

- **Auto-refresh:**
  - Automatically refreshes data every 5 seconds
  - Can be toggled on/off with the "Auto-Refresh" button
  - Manual refresh available with the "Aktualisieren" button

### 2. API Endpoints

#### GET `/api/live_stats`

Returns real-time statistics for the event system.

**Parameters:**
- `event_id` (optional): Filter statistics by specific event

**Response:**
```json
{
  "success": true,
  "stats": {
    "total_tickets": 150,
    "checked_in": 45,
    "not_checked_in": 105,
    "scans_last_minute": 3,
    "arrival_distribution": [
      {"hour": "2025-10-27 18:00", "count": 12},
      {"hour": "2025-10-27 19:00", "count": 25}
    ],
    "last_updated": "2025-10-27T19:30:00+00:00"
  }
}
```

#### GET `/api/live_list`

Returns lists of present and missing attendees.

**Parameters:**
- `event_id` (optional): Filter lists by specific event

**Response:**
```json
{
  "success": true,
  "present": [
    {
      "name": "Max Mustermann",
      "ticket_number": 1,
      "checked_in_at": "2025-10-27T18:30:00+00:00",
      "reference": "ABC123"
    }
  ],
  "missing": [
    {
      "name": "Erika Mustermann",
      "ticket_number": 2,
      "reference": "ABC123"
    }
  ],
  "last_updated": "2025-10-27T19:30:00+00:00"
}
```

### 3. Progressive Web App (PWA)

The ticket scanner can now be installed as a standalone app on mobile devices.

**Features:**
- **Installable:** Can be installed on home screen (Chrome, Android, iOS)
- **Offline Support:** Service worker caches essential resources
- **Full-screen Mode:** Runs in standalone display mode
- **App Icons:** Custom 192px and 512px icons

**Installation:**
1. Open the ticket scanner in Chrome on mobile
2. Tap the browser menu
3. Select "Add to Home Screen" or "Install App"
4. The app will be added to your home screen

**Manifest Details:**
- **Name:** Abiball Ticket Scanner
- **Start URL:** `/ticket_scanner.html`
- **Display:** Standalone (full-screen, no browser UI)
- **Theme Color:** Blue (#0d6efd)
- **Background Color:** Dark (#212529)

**Service Worker:**
- Caches static assets (CSS, JS, images) for offline access
- Network-first strategy for API calls
- Automatic cache updates
- Offline fallback responses

## Technical Implementation

### Database Queries

The live statistics use efficient Neo4j queries:

```cypher
# Get checked-in vs not-checked-in counts
MATCH (o:TicketOrder)-[:INCLUDES]->(p:Participant)
MATCH (o)-[:FOR]->(e:Event)
WHERE o.status = 'paid'
RETURN 
  COUNT(p) AS total_tickets,
  SUM(CASE WHEN p.redeemed = true THEN 1 ELSE 0 END) AS checked_in

# Get recent scans (last minute)
MATCH (o:TicketOrder)-[:INCLUDES]->(p:Participant)
WHERE p.redeemed = true AND p.redeemed_at > $one_minute_ago
RETURN COUNT(p) AS count

# Get arrival distribution (last 12 hours)
MATCH (o:TicketOrder)-[:INCLUDES]->(p:Participant)
WHERE p.redeemed = true AND p.redeemed_at > $twelve_hours_ago
WITH datetime(p.redeemed_at) AS dt
RETURN dt.year, dt.month, dt.day, dt.hour, COUNT(*) AS count
```

### Performance Considerations

- **Minimal Payloads:** API responses are kept small for quick updates
- **Efficient Queries:** Database queries are optimized for performance
- **Client-side Caching:** Service worker caches static resources
- **Configurable Refresh Rate:** Dashboard refresh interval can be adjusted

### Security

- **Permission-based Access:** Live dashboard requires `manage_orders` permission
- **No Sensitive Data Exposure:** API endpoints only return necessary information
- **HTTPS Required:** PWA features require HTTPS in production

## Browser Support

### PWA Installation:
- ✅ Chrome (desktop & mobile)
- ✅ Edge
- ✅ Samsung Internet
- ✅ Safari (iOS 11.3+, limited support)
- ❌ Firefox (limited PWA support)

### Dashboard:
- ✅ All modern browsers with JavaScript enabled
- ✅ Chart.js 4.4.0+ required for visualizations

## Troubleshooting

### PWA Not Installing
1. Ensure the site is served over HTTPS
2. Check that `site.webmanifest` is accessible
3. Verify service worker is registered (check browser console)
4. Clear browser cache and try again

### Dashboard Not Updating
1. Check browser console for JavaScript errors
2. Verify user has `manage_orders` permission
3. Ensure auto-refresh is enabled
4. Check network connectivity

### Statistics Show Zero
1. Verify that tickets have been sold and marked as paid
2. Check that some tickets have been redeemed/checked-in
3. Ensure event data exists in the database

## Future Enhancements

Possible improvements for future versions:
- WebSocket support for real-time push updates
- Export functionality for statistics
- More granular time ranges for arrival distribution
- Push notifications for check-ins
- Offline queue for check-ins when network is unavailable
