class Main < Sinatra::Base
    post "/api/tags" do
        require_user_with_permission!("view_users")
        
        tags = neo4j_query(<<~END_OF_QUERY)
            MATCH (t:Tag)
            OPTIONAL MATCH (u:User)-[:HAS_TAG]->(t)
            WITH t, COUNT(u) as user_count, COLLECT(u.username) as usernames
            RETURN t.name AS name, 
                   COALESCE(t.color, '#6c757d') AS color, 
                   user_count,
                   usernames
            ORDER BY t.name
        END_OF_QUERY
        
        respond(success: true, tags: tags)
    end

    post "/api/edit_tag" do
        require_user_with_permission!("edit_users")
        data = parse_request_data(required_keys: [:name], optional_keys: [:old_name, :color])
        
        name = data[:name].strip
        old_name = data[:old_name]&.strip
        color = data[:color] || '#6c757d'
        
        if name.empty?
            respond(success: false, error: "Tag-Name darf nicht leer sein")
            return
        end
        
        # Check if we're updating (old_name provided) or creating
        if old_name && !old_name.empty?
            # Update case
            if old_name != name
                # Check if new name already exists
                existing = neo4j_query(<<~END_OF_QUERY, {name: name})
                    MATCH (t:Tag {name: $name})
                    RETURN t
                END_OF_QUERY
                
                if !existing.empty?
                    respond(success: false, error: "Ein Tag mit diesem Namen existiert bereits")
                    return
                end
            end
            
            # Update tag
            neo4j_query(<<~END_OF_QUERY, {old_name: old_name, name: name, color: color})
                MATCH (t:Tag {name: $old_name})
                SET t.name = $name, t.color = $color
            END_OF_QUERY
            
            log("Tag '#{old_name}' aktualisiert zu '#{name}' mit Farbe #{color}")
            respond(success: true, message: "Tag erfolgreich aktualisiert")
        else
            # Create case
            existing = neo4j_query(<<~END_OF_QUERY, {name: name})
                MATCH (t:Tag {name: $name})
                RETURN t
            END_OF_QUERY
            
            if !existing.empty?
                respond(success: false, error: "Ein Tag mit diesem Namen existiert bereits")
                return
            end
            
            # Create new tag
            neo4j_query(<<~END_OF_QUERY, {name: name, color: color})
                CREATE (t:Tag {name: $name, color: $color})
            END_OF_QUERY
            
            log("Tag '#{name}' erstellt mit Farbe #{color}")
            respond(success: true, message: "Tag erfolgreich erstellt")
        end
    end

    
    post "/api/delete_tag" do
        require_user_with_permission!("edit_users")
        data = parse_request_data(required_keys: [:name])
        
        name = data[:name].strip
        
        # Delete tag and all relationships
        neo4j_query(<<~END_OF_QUERY, {name: name})
            MATCH (t:Tag {name: $name})
            DETACH DELETE t
        END_OF_QUERY
        
        log("Tag '#{name}' gelöscht")
        respond(success: true, message: "Tag erfolgreich gelöscht")
    end
    
    post "/api/tag" do
        require_user_with_permission!("view_users")
        data = parse_request_data(required_keys: [:tag])
        tag = data[:tag].strip
        
        users = neo4j_query(<<~END_OF_QUERY, {tag: tag})
            MATCH (u:User)-[:HAS_TAG]->(t:Tag {name: $tag})
            RETURN u.username AS username, 
                   u.name AS name, 
                   u.email AS email
            ORDER BY u.name
        END_OF_QUERY
        
        respond(success: true, users: users)
    end

    post "/api/tag/bulk_permission" do
        require_user_with_permission!("edit_users")
        data = parse_request_data(required_keys: [:tag, :permission, :action])

        tag        = data[:tag].strip
        permission = data[:permission].strip
        action     = data[:action].strip.downcase

        unless PERMISSIONS.include?(permission) || !user_has_permission?(permission)
            respond(success: false, error: "Ungültige Berechtigung: #{permission}")
            return
        end

        unless %w[grant remove].include?(action)
            respond(success: false, error: "Ungültige Aktion (grant|remove erwartet)")
            return
        end

        users = neo4j_query(<<~END_OF_QUERY, {tag: tag})
            MATCH (u:User)-[:HAS_TAG]->(t:Tag {name: $tag})
            RETURN u.username AS username
        END_OF_QUERY
        user_count = users.length

        if action == "grant"
            neo4j_query(<<~END_OF_QUERY, {tag: tag, permission: permission})
                MATCH (u:User)-[:HAS_TAG]->(t:Tag {name: $tag})
                MERGE (p:Permission {name: $permission})
                MERGE (u)-[:HAS_PERMISSION]->(p)
            END_OF_QUERY
            log("Berechtigung '#{permission}' wurde #{user_count} Benutzern mit Tag '#{tag}' erteilt")
            respond(success: true, message: "Berechtigung wurde #{user_count} Benutzern erteilt")
        else
            neo4j_query(<<~END_OF_QUERY, {tag: tag, permission: permission})
                MATCH (u:User)-[:HAS_TAG]->(t:Tag {name: $tag})
                MATCH (u)-[r:HAS_PERMISSION]->(p:Permission {name: $permission})
                DELETE r
            END_OF_QUERY
            log("Berechtigung '#{permission}' wurde von #{user_count} Benutzern mit Tag '#{tag}' entfernt")
            respond(success: true, message: "Berechtigung wurde von #{user_count} Benutzern entfernt")
        end
    end

    post "/api/edit_user_tags" do
        require_user_with_permission!("edit_users")
        data = parse_request_data(required_keys: [:username, :tag, :action])
        
        username = data[:username].strip
        tag = data[:tag].strip
        action = data[:action].strip.downcase
        
        if tag.empty?
            respond(success: false, error: "Tag-Name darf nicht leer sein")
            return
        end
        
        unless %w[add remove].include?(action)
            respond(success: false, error: "Ungültige Aktion (add|remove erwartet)")
            return
        end
        
        # Check if user exists
        user = neo4j_query(<<~END_OF_QUERY, {username: username})
            MATCH (u:User {username: $username})
            RETURN u
        END_OF_QUERY
        
        if user.empty?
            respond(success: false, error: "Benutzer nicht gefunden")
            return
        end
        
        if action == "add"
            # Create tag if it doesn't exist and add relationship
            neo4j_query(<<~END_OF_QUERY, {username: username, tag: tag})
                MERGE (t:Tag {name: $tag})
                WITH t
                MATCH (u:User {username: $username})
                MERGE (u)-[:HAS_TAG]->(t)
            END_OF_QUERY
            
            log("Tag '#{tag}' zu Benutzer '#{username}' hinzugefügt")
            respond(success: true, message: "Tag erfolgreich hinzugefügt")
        else
            # Remove tag relationship from user
            neo4j_query(<<~END_OF_QUERY, {username: username, tag: tag})
                MATCH (u:User {username: $username})-[r:HAS_TAG]->(t:Tag {name: $tag})
                DELETE r
            END_OF_QUERY
            
            log("Tag '#{tag}' von Benutzer '#{username}' entfernt")
            respond(success: true, message: "Tag erfolgreich entfernt")
        end
    end
end