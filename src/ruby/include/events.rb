class Main < Sinatra::Base

    # Event management for multi-event support
    
    # Helper method to get common event fields for queries
    def event_query_fields
        <<~FIELDS.strip
            e.id AS id,
            e.name AS name,
            e.year AS year,
            e.location AS location,
            e.description AS description,
            e.visibility AS visibility,
            e.max_tickets AS max_tickets,
            e.ticket_price AS ticket_price,
            e.start_datetime AS start_datetime,
            e.end_datetime AS end_datetime,
            e.max_tickets_per_user AS max_tickets_per_user,
            e.ticket_generation_enabled AS ticket_generation_enabled,
            e.ticket_sale_start_datetime AS ticket_sale_start_datetime,
            e.ticket_sale_end_datetime AS ticket_sale_end_datetime,
            e.target_tickets AS target_tickets,
            e.expected_users AS expected_users,
            e.payment_required AS payment_required,
            e.created_by AS created_by,
            e.created_at AS created_at
        FIELDS
    end
    
    # Helper method to check if user can manage an event (admin or creator)
    def can_manage_event?(event_creator)
        user_has_permission?("admin") || @session_user[:username] == event_creator
    end
    
    # Helper method to check if user is event creator or admin
    def is_event_creator_or_admin?
        user_logged_in? && (user_has_permission?("create_events") || user_has_permission?("admin"))
    end
    
    # Helper method to check if user can view private event
    def can_view_private_event?(event_creator)
        user_logged_in? && (user_has_permission?("create_events") || user_has_permission?("admin") || @session_user[:username] == event_creator)
    end
    
    # Helper method to require event management permission
    def require_event_management_permission!(event_id, require_active: false)
        where_clause = "e.id = $event_id"
        where_clause += " AND e.active = true" if require_active
        
        event = neo4j_query_expect_one(<<~END_OF_QUERY, {event_id: event_id})
            MATCH (e:Event)
            WHERE #{where_clause}
            RETURN e.created_by AS created_by
        END_OF_QUERY
        
        unless can_manage_event?(event['created_by'])
            respond(success: false, error: 'Access denied')
            halt
        end
        
        event
    end
    
    # Helper method to get events with visibility filter
    def get_filtered_events(visibility_filter = nil)
        where_clause = "e.active = true"
        where_clause += " AND e.visibility = 'public'" if visibility_filter == :public_only
        
        neo4j_query(<<~END_OF_QUERY)
            MATCH (e:Event)
            WHERE #{where_clause}
            RETURN #{event_query_fields}
            ORDER BY e.created_at DESC
        END_OF_QUERY
    end
    
    # Create a new event
    post "/api/create_event" do
        require_user_with_permission!("create_events")
        data = parse_request_data(
            required_keys: [:name, :year, :location], 
            optional_keys: [:description, :password, :visibility, :max_tickets, :ticket_price, :start_datetime, :end_datetime, :max_tickets_per_user, :ticket_generation_enabled, :ticket_sale_start_datetime, :ticket_sale_end_datetime, :target_tickets, :expected_users, :payment_required],
            types: {year: Integer, max_tickets: Integer, max_tickets_per_user: Integer, ticket_generation_enabled: :boolean, target_tickets: Integer, expected_users: Integer, payment_required: :boolean}
        )
        
        # Generate unique event ID
        event_id = RandomTag::generate(16)
        
        # Set defaults
        visibility = data[:visibility] || 'public'  # public, private, password_protected
        max_tickets = data[:max_tickets] || 200
        ticket_price = data[:ticket_price] || 65.0
        max_tickets_per_user = data[:max_tickets_per_user] || 10
        ticket_generation_enabled = data[:ticket_generation_enabled].nil? ? true : data[:ticket_generation_enabled]
        payment_required = data[:payment_required].nil? ? true : data[:payment_required]
        
        # Validate visibility setting
        unless ['public', 'private', 'password_protected'].include?(visibility)
            respond(success: false, error: 'Invalid visibility setting')
            return
        end
        
        # If password protected, ensure password is provided
        if visibility == 'password_protected' && (data[:password].nil? || data[:password].strip.empty?)
            respond(success: false, error: 'Password is required for password-protected events')
            return
        end
        
        event_params = {
            id: event_id,
            name: data[:name],
            year: data[:year],
            location: data[:location],
            description: data[:description] || '',
            password: visibility == 'password_protected' ? data[:password] : nil,
            visibility: visibility,
            max_tickets: max_tickets,
            ticket_price: ticket_price,
            start_datetime: data[:start_datetime],
            end_datetime: data[:end_datetime],
            max_tickets_per_user: max_tickets_per_user,
            ticket_generation_enabled: ticket_generation_enabled,
            ticket_sale_start_datetime: data[:ticket_sale_start_datetime],
            ticket_sale_end_datetime: data[:ticket_sale_end_datetime],
            target_tickets: data[:target_tickets],
            expected_users: data[:expected_users],
            payment_required: payment_required,
            created_by: @session_user[:username],
            created_at: DateTime.now.to_s,
            active: true
        }
        
        neo4j_query(<<~END_OF_QUERY, event_params)
            CREATE (e:Event {
                id: $id,
                name: $name,
                year: $year,
                location: $location,
                description: $description,
                password: $password,
                visibility: $visibility,
                max_tickets: $max_tickets,
                ticket_price: $ticket_price,
                start_datetime: $start_datetime,
                end_datetime: $end_datetime,
                max_tickets_per_user: $max_tickets_per_user,
                ticket_generation_enabled: $ticket_generation_enabled,
                ticket_sale_start_datetime: $ticket_sale_start_datetime,
                ticket_sale_end_datetime: $ticket_sale_end_datetime,
                target_tickets: $target_tickets,
                expected_users: $expected_users,
                payment_required: $payment_required,
                created_by: $created_by,
                created_at: $created_at,
                active: $active
            })
        END_OF_QUERY
        
        # Create relationship between user and event
        neo4j_query(<<~END_OF_QUERY, {username: @session_user[:username], event_id: event_id})
            MATCH (u:User {username: $username})
            MATCH (e:Event {id: $event_id})
            CREATE (u)-[:CREATED]->(e)
        END_OF_QUERY
        
        respond(success: true, event_id: event_id)
        log("Event '#{data[:name]}' erstellt")
    end
    
    # Get all events (filtered by visibility and user permissions)
    post "/api/get_events" do
        require_user!
        # Determine visibility filter based on user permissions
        if is_event_creator_or_admin?
            # Event creators and admins can see all events
            events = get_filtered_events
        else
            # Regular users and non-logged-in users only see public events
            events = get_filtered_events(:public_only)
        end
        
        respond(success: true, events: events)
    end
    
    # Get specific event details
    post "/api/get_event" do
        require_user!
        data = parse_request_data(required_keys: [:event_id])
        
        event = neo4j_query_expect_one(<<~END_OF_QUERY, {event_id: data[:event_id]})
            MATCH (e:Event {id: $event_id})
            WHERE e.active = true
            RETURN e.id AS id,
                   e.name AS name,
                   e.year AS year,
                   e.location AS location,
                   e.description AS description,
                   e.visibility AS visibility,
                   e.max_tickets AS max_tickets,
                   e.ticket_price AS ticket_price,
                   e.target_tickets AS target_tickets,
                   e.expected_users AS expected_users,
                   e.payment_required AS payment_required,
                   e.created_by AS created_by,
                   e.created_at AS created_at,
                   e.password AS password
        END_OF_QUERY
        
        # Check if user can access this event
        if event['visibility'] == 'private'
            unless can_view_private_event?(event['created_by'])
                respond(success: false, error: 'Access denied')
                return
            end
        end
        
        # Remove password from response unless user is the creator or admin
        unless user_logged_in? && can_manage_event?(event['created_by'])
            event.delete('password')
        end
        
        respond(success: true, event: event)
    end
    
    # Verify event password
    post "/api/verify_event_password" do
        require_user!
        data = parse_request_data(required_keys: [:event_id, :password])
        
        event = neo4j_query_expect_one(<<~END_OF_QUERY, {event_id: data[:event_id]})
            MATCH (e:Event {id: $event_id})
            WHERE e.active = true AND e.visibility = 'password_protected'
            RETURN e.password AS password
        END_OF_QUERY
        
        if event['password'] == data[:password]
            # Store event access in session (you might want to implement this differently)
            session["event_access_#{data[:event_id]}"] = true
            respond(success: true)
        else
            respond(success: false, error: 'Invalid password')
        end
    end
    
    # Update event
    post "/api/update_event" do
        require_user_with_permission!("create_events")
        data = parse_request_data(
            required_keys: [:event_id],
            optional_keys: [:name, :year, :location, :description, :password, :visibility, :max_tickets, :ticket_price, :start_datetime, :end_datetime, :max_tickets_per_user, :ticket_generation_enabled, :ticket_sale_start_datetime, :ticket_sale_end_datetime, :target_tickets, :expected_users, :payment_required, :active],
            types: {year: Integer, max_tickets: Integer, ticket_price: Float, max_tickets_per_user: Integer, ticket_generation_enabled: :boolean, target_tickets: Integer, expected_users: Integer, payment_required: :boolean, active: :boolean},
            max_body_length: 10 * 1024 * 1024,
            max_string_length: 5 * 1024 * 1024,
        )
        
        # Check if user can edit this event
        require_event_management_permission!(data[:event_id])
        
        # Build update query dynamically based on provided fields
        updates = []
        params = {event_id: data[:event_id]}
        
        [:name, :year, :location, :description, :password, :visibility, :max_tickets, :ticket_price, :start_datetime, :end_datetime, :max_tickets_per_user, :ticket_generation_enabled, :ticket_sale_start_datetime, :ticket_sale_end_datetime, :target_tickets, :expected_users, :payment_required, :active].each do |field|
            if data.key?(field)
                updates << "e.#{field} = $#{field}"
                params[field] = data[field]
            end
        end
        
        if updates.any?
            updates << "e.updated_at = $updated_at"
            params[:updated_at] = DateTime.now.to_s
            
            neo4j_query(<<~END_OF_QUERY, params)
                MATCH (e:Event {id: $event_id})
                SET #{updates.join(', ')}
            END_OF_QUERY
        end
        
        respond(success: true)
        log("Event #{data[:event_id]} aktualisiert")
    end
    
    # Delete event (soft delete by setting active = false)
    post "/api/delete_event" do
        require_user_with_permission!("create_events")
        data = parse_request_data(required_keys: [:event_id])
        
        # Check if user can delete this event
        require_event_management_permission!(data[:event_id])
        
        neo4j_query(<<~END_OF_QUERY, {event_id: data[:event_id], updated_at: DateTime.now.to_s})
            MATCH (e:Event {id: $event_id})
            SET e.active = false, e.updated_at = $updated_at
        END_OF_QUERY
        
        respond(success: true)
        log("Event #{data[:event_id]} gelöscht")
    end

    # Ticket Tier Management for Events
    
    # Get ticket tiers for an event
    post "/api/get_ticket_tiers" do
        require_user_with_permission!("buy_tickets")
        data = parse_request_data(required_keys: [:event_id])
        
        tiers = neo4j_query(<<~END_OF_QUERY, {event_id: data[:event_id]})
            MATCH (e:Event {id: $event_id})-[:HAS_TIER]->(t:TicketTier)
            WHERE e.active = true
            RETURN t.id AS id, t.name AS name, t.price AS price, t.description AS description, t.max_tickets AS max_tickets
            ORDER BY t.price ASC
        END_OF_QUERY
        
        # If no tiers exist, return the default tier based on event's base price
        if tiers.empty?
            event = neo4j_query_expect_one(<<~END_OF_QUERY, {event_id: data[:event_id]})
                MATCH (e:Event {id: $event_id})
                WHERE e.active = true
                RETURN e.ticket_price AS price, e.max_tickets AS max_tickets
            END_OF_QUERY
            
            tiers = [{
                'id' => 'default',
                'name' => 'Standard',
                'price' => event['price'],
                'description' => 'Standard Ticket',
                'max_tickets' => event['max_tickets']
            }]
        end
        
        respond(success: true, tiers: tiers)
    end
    
    # Create or update ticket tiers for an event (Admin only)
    post "/api/manage_ticket_tiers" do
        require_user_with_permission!("create_events")
        data = parse_request_data(
            required_keys: [:event_id, :tiers],
            types: {tiers: Array}
        )
        
        # Verify event exists and user has permission
        require_event_management_permission!(data[:event_id], require_active: true)
        
        # Delete existing tiers
        neo4j_query(<<~END_OF_QUERY, {event_id: data[:event_id]})
            MATCH (e:Event {id: $event_id})-[:HAS_TIER]->(t:TicketTier)
            DETACH DELETE t
        END_OF_QUERY
        
        # Create new tiers
        data[:tiers].each_with_index do |tier, index|
            tier_id = RandomTag::generate(12)
            tier_params = {
                event_id: data[:event_id],
                tier_id: tier_id,
                name: tier['name'] || "Tier #{index + 1}",
                price: tier['price'].to_f,
                description: tier['description'] || '',
                max_tickets: tier['max_tickets']&.to_i
            }
            neo4j_query(<<~END_OF_QUERY, tier_params)
                MATCH (e:Event {id: $event_id})
                CREATE (t:TicketTier {
                    id: $tier_id,
                    name: $name,
                    price: $price,
                    description: $description,
                    max_tickets: $max_tickets
                })
                CREATE (e)-[:HAS_TIER]->(t)
            END_OF_QUERY
        end
        
        respond(success: true)
        log("Ticket-Kategorien für Event #{data[:event_id]} aktualisiert")
    end

    # Bank Account Management for Events
    
    # Get bank accounts for an event
    post "/api/get_bank_accounts" do
        require_user_with_permission!("buy_tickets")
        data = parse_request_data(required_keys: [:event_id])
        
        accounts = neo4j_query(<<~END_OF_QUERY, {event_id: data[:event_id]})
            MATCH (e:Event {id: $event_id})-[:HAS_BANK_ACCOUNT]->(b:BankAccount)
            WHERE e.active = true
            RETURN b.id AS id, b.account_name AS account_name, b.bank_name AS bank_name, 
                   b.iban AS iban, b.bic AS bic, b.percentage AS percentage,
                   b.escrow_document_url AS escrow_document_url
            ORDER BY b.percentage DESC
        END_OF_QUERY
        
        respond(success: true, accounts: accounts)
    end
    
    # Get escrow agreements for an event (public endpoint for users before ordering)
    post "/api/get_escrow_agreements" do
        require_user!
        data = parse_request_data(required_keys: [:event_id])
        
        accounts = neo4j_query(<<~END_OF_QUERY, {event_id: data[:event_id]})
            MATCH (e:Event {id: $event_id})-[:HAS_BANK_ACCOUNT]->(b:BankAccount)
            WHERE e.active = true AND b.escrow_document_url IS NOT NULL AND b.escrow_document_url <> ''
            RETURN b.id AS id, b.account_name AS account_name, 
                   b.escrow_document_url AS escrow_document_url
            ORDER BY b.account_name ASC
        END_OF_QUERY
        
        respond(success: true, escrow_agreements: accounts)
    end
    
    # Manage bank accounts for an event (Admin only)
    post "/api/manage_bank_accounts" do
        require_user_with_permission!("create_events")
        data = parse_request_data(
            required_keys: [:event_id, :accounts],
            types: {accounts: Array}
        )
        
        # Verify event exists and user has permission
        require_event_management_permission!(data[:event_id], require_active: true)
        
        # Validate that percentages sum to 100
        total_percentage = data[:accounts].sum { |acc| acc['percentage'].to_f }
        unless (total_percentage - 100.0).abs < 0.01
            respond(success: false, error: "Die Summe der Prozentsätze muss 100% ergeben (aktuell: #{total_percentage}%)")
            return
        end
        
        # Delete existing bank accounts
        neo4j_query(<<~END_OF_QUERY, {event_id: data[:event_id]})
            MATCH (e:Event {id: $event_id})-[:HAS_BANK_ACCOUNT]->(b:BankAccount)
            DETACH DELETE b
        END_OF_QUERY
        
        # Create new bank accounts
        data[:accounts].each do |account|
            account_id = RandomTag::generate(12)
            account_params = {
                event_id: data[:event_id],
                account_id: account_id,
                account_name: account['account_name'] || '',
                bank_name: account['bank_name'] || '',
                iban: account['iban'] || '',
                bic: account['bic'] || '',
                percentage: account['percentage'].to_f,
                escrow_document_url: account['escrow_document_url'] || ''
            }
            neo4j_query(<<~END_OF_QUERY, account_params)
                MATCH (e:Event {id: $event_id})
                CREATE (b:BankAccount {
                    id: $account_id,
                    account_name: $account_name,
                    bank_name: $bank_name,
                    iban: $iban,
                    bic: $bic,
                    percentage: $percentage,
                    escrow_document_url: $escrow_document_url
                })
                CREATE (e)-[:HAS_BANK_ACCOUNT]->(b)
            END_OF_QUERY
        end
        
        respond(success: true)
        log("Bankkonten für Event #{data[:event_id]} aktualisiert")
    end

    # User-Specific Event Settings Management
    
    # Get user-specific settings for an event
    post "/api/get_user_event_settings" do
        require_user_with_permission!("view_users")
        data = parse_request_data(required_keys: [:username, :event_id])
        
        # Get user-specific settings
        settings = neo4j_query(<<~END_OF_QUERY, {username: data[:username], event_id: data[:event_id]})
            MATCH (u:User {username: $username})
            MATCH (e:Event {id: $event_id})
            OPTIONAL MATCH (u)-[r:HAS_EVENT_LIMIT]->(e)
            RETURN r.ticket_price AS custom_price,
                   r.ticket_limit AS custom_limit,
                   e.ticket_price AS default_price,
                   e.max_tickets_per_user AS default_limit,
                   e.name AS event_name
        END_OF_QUERY
        
        if settings.empty?
            respond(success: false, error: "User or event not found")
            return
        end
        
        result = settings.first
        respond(success: true, settings: result)
    end
    
    # Get all user-specific event settings for a user
    post "/api/get_user_all_event_settings" do
        require_user_with_permission!("view_users")
        data = parse_request_data(required_keys: [:username])
        
        # Get all user-specific event settings
        settings = neo4j_query(<<~END_OF_QUERY, {username: data[:username]})
            MATCH (u:User {username: $username})
            MATCH (e:Event)
            WHERE e.active = true
            OPTIONAL MATCH (u)-[r:HAS_EVENT_LIMIT]->(e)
            RETURN e.id AS event_id,
                   e.name AS event_name,
                   e.ticket_price AS default_price,
                   e.max_tickets_per_user AS default_limit,
                   r.ticket_price AS custom_price,
                   r.ticket_limit AS custom_limit
            ORDER BY e.name ASC
        END_OF_QUERY
        
        respond(success: true, settings: settings)
    end
    
    # Set user-specific event settings
    post "/api/set_user_event_settings" do
        require_user_with_permission!("edit_users")
        data = parse_request_data(
            required_keys: [:username, :event_id],
            optional_keys: [:custom_price, :custom_limit],
            types: {custom_price: Float, custom_limit: Integer}
        )
        
        username = data[:username]
        event_id = data[:event_id]
        custom_price = data[:custom_price]
        custom_limit = data[:custom_limit]
        
        # Verify user and event exist
        user_exists = neo4j_query(<<~END_OF_QUERY, {username: username})
            MATCH (u:User {username: $username})
            RETURN u.username AS username
        END_OF_QUERY
        
        if user_exists.empty?
            respond(success: false, error: "User not found")
            return
        end
        
        event_exists = neo4j_query(<<~END_OF_QUERY, {event_id: event_id})
            MATCH (e:Event {id: $event_id})
            WHERE e.active = true
            RETURN e.id AS id
        END_OF_QUERY
        
        if event_exists.empty?
            respond(success: false, error: "Event not found")
            return
        end
        
        # If both custom_price and custom_limit are nil, remove the relationship
        if custom_price.nil? && custom_limit.nil?
            neo4j_query(<<~END_OF_QUERY, {username: username, event_id: event_id})
                MATCH (u:User {username: $username})-[r:HAS_EVENT_LIMIT]->(e:Event {id: $event_id})
                DELETE r
            END_OF_QUERY
            log("Benutzerspezifische Event-Einstellungen für #{username} bei Event #{event_id} entfernt")
        else
            # Create or update the relationship with custom settings
            params = {
                username: username,
                event_id: event_id,
                custom_price: custom_price,
                custom_limit: custom_limit
            }
            
            neo4j_query(<<~END_OF_QUERY, params)
                MATCH (u:User {username: $username})
                MATCH (e:Event {id: $event_id})
                MERGE (u)-[r:HAS_EVENT_LIMIT]->(e)
                SET r.ticket_price = $custom_price,
                    r.ticket_limit = $custom_limit,
                    r.updated_at = datetime()
            END_OF_QUERY
            
            log("Benutzerspezifische Event-Einstellungen für #{username} bei Event #{event_id} aktualisiert")
        end
        
        respond(success: true)
    end
    
    # Remove user-specific event settings
    post "/api/remove_user_event_settings" do
        require_user_with_permission!("edit_users")
        data = parse_request_data(required_keys: [:username, :event_id])
        
        neo4j_query(<<~END_OF_QUERY, {username: data[:username], event_id: data[:event_id]})
            MATCH (u:User {username: $username})-[r:HAS_EVENT_LIMIT]->(e:Event {id: $event_id})
            DELETE r
        END_OF_QUERY
        
        respond(success: true)
        log("Benutzerspezifische Event-Einstellungen für #{data[:username]} bei Event #{data[:event_id]} entfernt")
    end

end