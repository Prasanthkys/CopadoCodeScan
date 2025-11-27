/**
 * SampleContactService
 *
 * A reusable, flow-invocable Apex service demonstrating:
 * - with sharing for security
 * - InvocableMethod for Flow
 * - Enums instead of string literals
 * - Database methods (USER_MODE) with error handling and early returns
 * - FLS checks and safe field access
 * - Bulkified processing without SOQL/DML in loops
 * - ApexDocs for maintainability
 */
public with sharing class SampleContactService {
    /**
     * Operation types supported by this service.
     */
    public enum OPERATION_TYPE {
        CREATE_CONTACTS_FROM_LEADS
    }

    /**
     * Request DTO for flow invocation.
     * Pass a list of Lead Ids to create Contacts.
     */
    public class Request {
        @InvocableVariable(required=true)
        public List<Id> leadIds;

        @InvocableVariable
        public String firstNameFallback;

        @InvocableVariable
        public String lastNameFallback;
    }

    /**
     * Response DTO for flow invocation.
     * Contains results and any error messages.
     */
    public class Response {
        @InvocableVariable
        public List<Id> createdContactIds = new List<Id>();

        @InvocableVariable
        public List<String> errors = new List<String>();

        @InvocableVariable
        public Integer successCount = 0;

        @InvocableVariable
        public Integer errorCount = 0;
    }

    /**
     * Flow-invocable entry point to create Contacts from Leads.
     * - Bulkified: processes all input in collections
     * - Uses Database.insert with USER_MODE to respect CRUD/FLS and sharing
     * - Returns granular error information
     *
     * @param requests list of Request payloads from Flow (supports batch invocation)
     * @return list of Response objects corresponding to each Request
     */
    @InvocableMethod(label='Create Contacts From Leads' description='Creates Contacts from provided Lead Ids using USER_MODE and returns per-request results.')
    public static List<Response> createContactsFromLeads(List<Request> requests) {
        List<Response> results = new List<Response>();
        if (requests == null || requests.isEmpty()) {
            return results; // Early return
        }

        for (Request req : requests) {
            Response res = new Response();
            results.add(res);

            // Guard clauses
            if (req == null || req.leadIds == null || req.leadIds.isEmpty()) {
                System.debug('SampleContactService class');
                res.errors.add('No Lead Ids provided.');
                res.errorCount = res.errors.size();
                continue;
            }

            // Enforce FLS for Contact fields we intend to set
            if (!Schema.sObjectType.Contact.fields.LastName.isCreateable()) {
                res.errors.add('Insufficient access: Contact.LastName is not createable.');
                res.errorCount = res.errors.size();
                continue;
            }
            // Optional fields - check FLS before setting later

            // Query required Lead fields with security enforced
            Map<Id, Lead> leadsById = new Map<Id, Lead>(
                [SELECT Id, FirstName, LastName, Company
                 FROM Lead
                 WHERE Id IN :req.leadIds
                 WITH SECURITY_ENFORCED]
            );

            if (leadsById.isEmpty()) {
                res.errors.add('No Leads found for provided Ids or insufficient access.');
                res.errorCount = res.errors.size();
                continue;
            }

            List<Contact> toInsert = new List<Contact>();
            for (Id leadId : req.leadIds) {
                Lead ld = leadsById.get(leadId);
                if (ld == null) {
                    res.errors.add('Lead not found or inaccessible: ' + String.valueOf(leadId));
                    continue;
                }

                Contact c = new Contact();
                // Required field: LastName
                c.LastName = sanitizeName(
                    (ld.LastName != null && ld.LastName.trim().length() > 0)
                        ? ld.LastName
                        : (req.lastNameFallback != null && req.lastNameFallback.trim().length() > 0)
                            ? req.lastNameFallback
                            : 'Unknown'
                );

                // Optional: map first name if createable
                if (Schema.sObjectType.Contact.fields.FirstName.isCreateable()) {
                    String firstName = (ld.FirstName != null && ld.FirstName.trim().length() > 0)
                        ? ld.FirstName
                        : (req.firstNameFallback != null && req.firstNameFallback.trim().length() > 0)
                            ? req.firstNameFallback
                            : null;
                    if (firstName != null) {
                        c.FirstName = sanitizeName(firstName);
                    }
                }

                // Optional: map Company to Description if allowed (example)
                if (Schema.sObjectType.Contact.fields.Description.isCreateable() && ld.Company != null) {
                    c.Description = 'Source Lead Company: ' + ld.Company;
                }

                toInsert.add(c);
            }

            if (toInsert.isEmpty()) {
                res.errors.add('No valid Contacts to insert after validation.');
                res.errorCount = res.errors.size();
                continue;
            }

            // Perform DML in USER_MODE to respect CRUD/FLS/sharing
            Database.SaveResult[] srList = Database.insert(toInsert, /*allOrNone*/ false, AccessLevel.USER_MODE);

            // Collect results
            for (Integer i = 0; i < srList.size(); i++) {
                Database.SaveResult sr = srList[i];
                if (sr.isSuccess()) {
                    res.createdContactIds.add(sr.getId());
                    res.successCount++;
                } else {
                    for (Database.Error e : sr.getErrors()) {
                        res.errors.add('Row ' + i + ': ' + e.getStatusCode() + ' - ' + e.getMessage());
                    }
                }
            }
            res.errorCount = res.errors.size();
        }

        return results;
    }

    /**
     * Sanitizes a name by trimming and collapsing whitespace.
     * Returns null if the resulting value is empty.
     */
    public static String sanitizeName(String input) {
        if (String.isBlank(input)) {
            return null;
        }
        String trimmed = input.trim();
        // Collapse multiple spaces to single
        String collapsed = trimmed.replaceAll('\\s+', ' ');
        return collapsed.length() > 0 ? collapsed : null;
    }
}
