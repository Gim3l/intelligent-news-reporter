node dialog_state {

    can use.text_classify;
    can tfm_ner.extract_entity;
    can sentiment.predict;

    has name;

    can nlu {
        ::classify_intent;
        ::extract_entities;
        ::analyze_sentiment;
    }

    can process {}

    can nlg {}

    can cleanup with talker exit {}

    can resume {}

    can get_session {
        if(!visitor.resumed) {
            if(visitor.session_id): _session = spawn net.root() walker::load_user_session(session_id = visitor.session_id);
            else: _session = spawn net.root() walker::load_user_session;

            visitor.session_id = _session.session_id;
            if(_session.session_data) {
                for item in _session.session_data.dict::keys {
                    if(item != "utterance"): visitor.context[item] = _session.session_data[item];
                }
            }  
            visitor.resumed = true;
        }
    }

    can set_session {
        if(visitor.session_id): spawn net.root() walker::save_user_session(session_id = visitor.session_id, session_data = visitor.context);
    }

    can classify_intent { 

        intent = "";
        //grab all the available intent labels
        intent_labels = -[intent_transition]->.edge.intent;
        
        try {
            intent_data = file.load_json(global.intent_data);
        } else {
            std.log("Could not load intent data.");
        }
        
        if(intent_data) {
            min_confidence = global.min_intent_confidence;
        
            for item in intent_data {

                statements = intent_data[item];
        
                predicted_intent = use.text_classify(
                    text = visitor.utterance,
                    classes = statements.list
                );

                match_index = predicted_intent['match_idx'];
                confidence = predicted_intent['scores'][match_index];
                if (confidence > min_confidence) {
                    min_confidence = confidence;
                    intent = item;
                }                
            }
        }    
        visitor._debug.dict::update({"intent_confidence" : min_confidence});
        visitor._debug.dict::update({"predicted_intent" : intent});
            
        if(intent in intent_labels): visitor.intent = intent;
        
    }

    can extract_entities {
        
        try {
            entity_config = file.load_json(global.entity_config);
        } else {
            std.log("Could not load entity list.");
        }

        if(entity_config) {
            res = tfm_ner.extract_entity(visitor.utterance);
            visitor._debug.dict::update({"extracted_entities" : res});

            //prepare a standard way of organizing extracted entities inside of the walker
            //this can be modified if we swap out the NER without altering dependencies in the implementing app
            if(res.type == list || res.type == dict) {
                for entity in res {
                    if(entity["conf_score"] >= global.min_ner_confidence) {
                        entity_label = entity["entity_value"];
                        entity_text = entity["entity_text"];
                        entity_confidence = entity["conf_score"];
                                                
                        if(entity_label in entity_config["labels"]) { 
                            //only consider valid entities based on entity_config.json
                            //update the collection of entities in the walker, 
                            //appending new entity_texts to existing entity_labels
                            if(entity_label not in visitor.entity_data) {
                                visitor.entities[entity_label] = [entity_text];
                                visitor.entity_data[entity_label] = [{"text": entity_text, "confidence":entity_confidence}];
                            } else {
                                //we already have items under the label, ensure we only add unique items..
                                if(entity_text not in visitor.entities[entity_label]) {
                                    visitor.entities[entity_label] += [entity_text]; 
                                    visitor.entity_data[entity_label] += [{"text":entity_text, "confidence":entity_confidence}]; 
                                }                                
                            }
                        }
                    }
                }
            }
        }     

    }

    can analyze_sentiment {

        //run sentiment analysis on utterance
        
        sentiment_classes = {
            "POS": "positive",
            "NEG": "negative",
            "NEU": "neutral"
        };
        //establish default sentiment
        sentiment_result = "neutral";
        
        sentiment_data = sentiment.predict([visitor.utterance]);
        visitor._debug.dict::update({"sentiment_data" : sentiment_data});
        
        //parse and standardize sentiment data {class,confidence}
        if(sentiment_data) {
            item = sentiment_data[0];
            if( item["score"] >= global.min_sentiment_confidence ) {
                sentiment_result = sentiment_classes[item["label"]];
            }
        }

        visitor.sentiment = sentiment_result;

    }

    can set_state_response {
        //returns a random state response based on ext json file and exclude list
        exclude = [];
        try {
            state_responses = file.load_json(global.state_responses);
        } else {
            std.log("Could not load state responses.");
        }
        
        if(state_responses) {
            if(name in state_responses) {
                responses = state_responses[name];
                visitor.response = rand.choice(responses);
            } else {
                visitor.response = "Unfortunately, I don't have a response for that";
            }
        } else {
            visitor.response = "Unfortunately, I am unable to continue.";
        }

       
    }

}

node dialog_root:dialog_state {
    has name = "dialog_root";

    can resume {
        ::get_session;
    }

    can process {
        next_node = (-[intent_transition(intent==visitor.intent)]-> node::dialog_state);
        if(next_node) {
            visitor.next_state = next_node[0].info["jid"];
        }
        else: visitor.next_state = (net.root()).info["jid"];
    }

    can nlg {
        if(!visitor.intent): ::set_state_response;
    }
}

node greet:dialog_state {
    has name = "greet";

    can process {
        visitor.next_state = (net.root()).info["jid"];
    }

    can nlg {
        ::set_state_response;
    }
}

node semantic_search:dialog_state {
    has name = "semantic_search";

    can process {
        visitor.next_state = (net.root()).info["jid"];
    }

    can nlg {
        ::set_state_response;
    }
}

node entity_search:dialog_state {
    has name = "entity_search";

    can process {
        visitor.next_state = (net.root()).info["jid"];
    }

    can nlg {
        ::set_state_response;
    }
}

node add_preferences:dialog_state {
    has name = "add_preferences";
    can utils.replace_placeholders;
    has next_node;

    can nlu {
        ::classify_intent;
        ::extract_entities;
    }

    can process {
        next_node = (-[intent_transition(intent==visitor.intent)]-> node::dialog_state);
        if(next_node) {
            visitor.response = null;
            visitor.next_state = next_node[0].info["jid"];
        }
        else: visitor.next_state = here.info["jid"];
    }   

    can set_preferences {
        // if ("news_source" in visitor.entity_data.dict::keys) {
        //     for extracted_source in visitor.entity_data["news_source"] {
        //         std.log("extracted news source: "+extracted_source["text"]);
        //         if(extracted_source["text"] in visitor._context["news_source"]): std.log("already subscribed to news source: "+extracted_source["text"]);
        //         else: visitor._context["news_source"].list::append(extracted_source["text"]);
        //     }
        // }

        // if ("tag" in visitor.entity_data.dict::keys) {
        //     for extracted_tag in visitor.entity_data["tag"] {
        //         std.log("extracted tag: "+extracted_tag["text"]);
        //         if(extracted_tag["text"] in visitor._context["tags"]): std.log("already subscribed to tag: "+extracted_tag["text"]);
        //         else: visitor._context["tags"].list::append(extracted_tag["text"]);
        //     }
        // }

        for entity in visitor.entity_data.dict::keys{
            if(entity in ["tag", "news_source"]){
                // if entity not in _context; add it
                if (!(entity in visitor.preferences.dict::keys)): visitor.preferences[entity] = [];
                for _data in visitor.entity_data[entity]{
                    if(_data in visitor.preferences[entity]): std.log("already subscribed to "+entity+": "+_data["text"]);
                    else: visitor.preferences[entity].list::append(_data);
                }
            }
        }
    }
    can nlg {
        if (!next_node){
            try {
                state_responses = file.load_json(global.state_responses);
                preferences_data = {};
                for entity in visitor.preferences{
                    if (!(entity in preferences_data.dict::keys)): preferences_data[entity] = [];
                    for _data in visitor.preferences[entity]{
                        if(_data["text"] in preferences_data[entity]): continue;
                        else: preferences_data[entity].list::append(_data["text"]);
                    }
                }
                response_list = utils.replace_placeholders(string_or_collection=state_responses["add_preferences"], placeholders=preferences_data);
                visitor.response = rand.choice(response_list);
            } else {
                std.log("Could not load state responses.");
            }
        }
    }
}

node update_preferences:dialog_state {
    has name = "update_preferences";
    can utils.replace_placeholders;
    has next_node;

    can nlu {
        ::classify_intent;
        ::extract_entities;
    }

    can process {
        next_node = (-[intent_transition(intent==visitor.intent)]-> node::dialog_state);
        if(next_node) {
            visitor.response = null;
            visitor.next_state = next_node[0].info["jid"];
        }
        else: visitor.next_state = here.info["jid"];
    }   

    can set_preferences {

        for entity in visitor.entity_data.dict::keys{
            if(entity in ["tag", "news_source"]){
                // if entity not in _context; add it
                if (!(entity in visitor.preferences.dict::keys)): visitor.preferences[entity] = [];
                for _data in visitor.entity_data[entity]{
                    if(_data in visitor.preferences[entity]): continue;
                    else: visitor.preferences[entity].list::append(_data);
                }
            }
        }
    }
    can nlg {
        if (!next_node){
            try {
                state_responses = file.load_json(global.state_responses);
                response_list = utils.replace_placeholders(string_or_collection=state_responses["update_preferences"], placeholders=visitor.preferences);
                visitor.response = rand.choice(response_list);
            } else {
                std.log("Could not load state responses.");
            }
        }
    }
}

node confirm_preferences:dialog_state{
    has name = "confirm_preferences";
    can utils.replace_placeholders;
    
    can process {
        next_node = (-[intent_transition(intent==visitor.intent)]-> node::dialog_state);
        if(next_node) {
            visitor.next_state = next_node[0].info["jid"];
        }
        else: visitor.next_state = (net.root()).info["jid"];
    }

    can update_context {
        if (visitor._debug["trail"][-1] == "add_preferences") {
            for entity in visitor.preferences.dict::keys{
                // if entity not in _context; add it
                if (!(entity in visitor._context.dict::keys)): visitor._context[entity] = [];
                for _data in visitor.preferences[entity]{
                    if(_data in visitor._context[entity]): continue;
                    else: visitor._context[entity].list::append(_data);
                }
            }       
        }
        else {
            for entity in visitor.preferences.dict::keys{
                for _data in visitor.preferences[entity]{
                    if(_data in visitor._context[entity]): 
                    visitor._context[entity].list::remove(_data);
                }
            }
        }
        // spawn net.root() walker::filter_posts_by_entities(entities =  visitor._context);
    }

    can nlg {
        
        try {
            state_responses = file.load_json(global.state_responses);
            preferences_data = {};
                for entity in visitor.preferences{
                    if (!(entity in preferences_data.dict::keys)): preferences_data[entity] = [];
                    for _data in visitor.preferences[entity]{
                        if(_data["text"] in preferences_data[entity]): continue;
                        else: preferences_data[entity].list::append(_data["text"]);
                    }
                }
            if (visitor._debug["trail"][-1] == "add_preferences"): response_list = utils.replace_placeholders(string_or_collection=state_responses["confirm_add_preferences"], placeholders=preferences_data);
            else: response_list = utils.replace_placeholders(string_or_collection=state_responses["confirm_update_preferences"], placeholders=preferences_data);
            visitor.response = rand.choice(response_list);
        } else {
            std.log("Could not load state responses.");
        }
        visitor.preferences = {};
    }
}

node current_preferences:dialog_state {
    has name = "current_preferences";
    can utils.replace_placeholders;

    can nlu {
        ::classify_intent;
    }

    can process {
        visitor.next_state = (net.root()).info["jid"];
    }   

    can nlg {
        try {
            state_responses = file.load_json(global.state_responses);
            response_list = utils.replace_placeholders(string_or_collection=state_responses["current_preferences"], placeholders=visitor._context);
            visitor.response = rand.choice(response_list);
        } else {
            std.log("Could not load state responses.");
        }
    }
}

node news_feed:dialog_state {
    has name = "news_feed";

    has entity_data;

    can process {
        visitor.next_state = (net.root()).info["jid"];
    }

    can get_session {
            if(visitor.session_id): _session = spawn net.root() walker::load_user_session(session_id = visitor.session_id);
            else: _session = spawn net.root() walker::load_user_session;

            visitor.session_id = _session.session_id;
            if(_session.session_data) {
                for item in _session.session_data.dict::keys {
                    if(item != "utterance"): visitor.context[item] = _session.session_data[item];
                }
            }
    }

    can generate_news_feed {
        std.log("This is your news feed.");
        if(visitor._context) {
            report spawn net.root() walker::filter_posts_by_entities(entities = visitor._context);
        }
        else {
            report "_context not found";
        }
    }   
}

node dialog_end:dialog_state {
    has name = "dialog_end";
    //the talker walker disengages when it gets here
}

edge intent_transition {
    has intent;
}

node sessions;

node session {
    has session_id;
    has session_data = {};
}