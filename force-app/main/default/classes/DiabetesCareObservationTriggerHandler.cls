public class DiabetesCareObservationTriggerHandler {
    
    public static void handleAfterInsert(List<CareObservation> newObservations) {
        processObservations(newObservations);
    }
    
    public static void handleAfterUpdate(List<CareObservation> newObservations) {
        processObservations(newObservations);
    }
    
    private static void processObservations(List<CareObservation> newObservations) {
        System.debug('newObservations: ' + JSON.serializePretty(newObservations));
        if (newObservations == null || newObservations.isEmpty()) {
            return;
        }
        // Get thresholds from Custom Metadata (cached automatically)
        List<Diabetes_Threshold__mdt> thresholdsList = [
            SELECT Target_Percentage__c, Warning_Percentage__c, Critical_Percentage__c
            FROM Diabetes_Threshold__mdt
            WHERE DeveloperName = 'Standard_Diabetes_Thresholds'
            LIMIT 1
        ];
        System.debug('thresholdsList: ' + JSON.serializePretty(thresholdsList));
        if (thresholdsList.isEmpty()) {
            return;
        }
        Diabetes_Threshold__mdt thresholds = thresholdsList[0];
        System.debug('thresholds: ' + JSON.serializePretty(thresholds));

        List<Task> tasksToCreate = new List<Task>();
        Set<Id> observationIds = new Set<Id>();
        Set<Id> codeIds = new Set<Id>();
        Map<Id, Decimal> observationHbA1cMap = new Map<Id, Decimal>();

        // First pass: collect Code IDs to query
        for (CareObservation obs : newObservations) {
            if (obs != null && obs.CodeId != null) {
                codeIds.add(obs.CodeId);
            }
        }

        // Query CodeSet records to get code names (guard empty IN-list)
        Map<Id, CodeSet> codeMap = new Map<Id, CodeSet>();
        if (!codeIds.isEmpty()) {
            for (CodeSet cs : [SELECT Id, Name FROM CodeSet WHERE Id IN :codeIds]) {
                codeMap.put(cs.Id, cs);
            }
        }
        System.debug('codeMap: ' + JSON.serializePretty(codeMap));

        // Second pass: collect observation IDs and HbA1c values for bulk processing
        for (CareObservation obs : newObservations) {
            if (obs == null) continue;

            CodeSet code = codeMap.get(obs.CodeId);
            String codeName = (code != null ? code.Name : null);

            // Only process finalized HbA1c observations with valid data
            if (codeName == 'HbA1c'
                && obs.ObservationStatus == 'final'
                && obs.ObservedValueType == 'Quantity'
                && obs.ObservedValueNumerator != null
                && obs.ObservedValueNumerator >= thresholds.Warning_Percentage__c
                && obs.ObservedSubjectId != null
                && obs.Id != null) {

                observationIds.add(obs.Id);
                observationHbA1cMap.put(obs.Id, obs.ObservedValueNumerator);
            }
        }
        System.debug('observationIds: ' + observationIds);
        System.debug('observationHbA1cMap: ' + JSON.serializePretty(observationHbA1cMap));

        if (observationIds.isEmpty()) {
            return;
        }

        // Bulk query existing follow-up tasks for all observations at once (fix Bug 1)
        Map<Id, List<Task>> existingTasksByWhatId = new Map<Id, List<Task>>();
        for (Task t : [
            SELECT Id, WhatId
            FROM Task
            WHERE WhatId IN :observationIds
              AND Subject LIKE '%HbA1c Follow-up%'
              AND Status != 'Completed'
              AND CreatedDate = LAST_N_DAYS:30
        ]) {
            List<Task> lst = existingTasksByWhatId.get(t.WhatId);
            if (lst == null) {
                lst = new List<Task>();
                existingTasksByWhatId.put(t.WhatId, lst);
            }
            lst.add(t);
        }

        Date today = Date.today();
        for (Id observationId : observationIds) {
            List<Task> existing = existingTasksByWhatId.get(observationId);
            if (existing == null || existing.isEmpty()) {
                Decimal hba1cValue = observationHbA1cMap.get(observationId);

                Task followUpTask = new Task();
                followUpTask.Subject = 'HbA1c Follow-up Required - ' + today.format();
                followUpTask.WhatId = observationId;

                // Set required ActivityDate (fix Bug 2)
                if (hba1cValue != null && hba1cValue >= thresholds.Critical_Percentage__c) {
                    followUpTask.ActivityDate = today.addDays(3);
                    followUpTask.Priority = 'High';
                } else if (hba1cValue != null && hba1cValue >= thresholds.Warning_Percentage__c) {
                    followUpTask.ActivityDate = today.addDays(7);
                    followUpTask.Priority = 'Normal';
                } else {
                    followUpTask.ActivityDate = today.addDays(14);
                    followUpTask.Priority = 'Low';
                }

                followUpTask.Status = 'Not Started';
                followUpTask.Type = 'Call';

                // Guard null for hba1cValue in concatenation (fix Bug 3)
                String hba1cText = (hba1cValue == null) ? 'N/A' : String.valueOf(hba1cValue);
                followUpTask.Description =
                    'Patient has new HbA1c level of ' + hba1cText +
                    '%. Schedule follow-up appointment to review diabetes management plan and medication adherence. ' +
                    'Thresholds: Target <' + String.valueOf(thresholds.Target_Percentage__c) +
                    '%, Warning ≥' + String.valueOf(thresholds.Warning_Percentage__c) +
                    '%, Critical ≥' + String.valueOf(thresholds.Critical_Percentage__c) + '%.';

                // Accumulate for bulk insert (fix Bug 4)
                tasksToCreate.add(followUpTask);
            }
        }

        if (!tasksToCreate.isEmpty()) {
            System.debug('Inserting ' + tasksToCreate.size() + ' follow-up tasks');
            Database.insert(tasksToCreate, false);
        }
    }
}