public with sharing class DiabetesCareObservationTriggerHandler {
    /**
     * Handle after insert of CareObservation
     */
    public static void handleAfterInsert(List<CareObservation> newObservations) {
        processObservations(newObservations);
    }

    /**
     * Handle after update of CareObservation
     */
    public static void handleAfterUpdate(List<CareObservation> newObservations) {
        processObservations(newObservations);
    }

    /**
     * Core processing - bulkified
     */
    private static void processObservations(List<CareObservation> newObservations) {
        if (newObservations == null || newObservations.isEmpty()) {
            return; // Return early
        }

        // Thresholds from CMDT (cached by platform)
        Diabetes_Threshold__mdt thresholds = [
            SELECT Target_Percentage__c, Warning_Percentage__c, Critical_Percentage__c
            FROM Diabetes_Threshold__mdt
            WHERE DeveloperName = 'Standard_Diabetes_Thresholds'
            LIMIT 1
        ];

        // Collect CodeIds for a single CodeSet query
        Set<Id> codeIds = new Set<Id>();
        for (CareObservation obs : newObservations) {
            if (obs.CodeId != null) {
                codeIds.add(obs.CodeId);
            }
        }

        Map<Id, CodeSet> codeMap = new Map<Id, CodeSet>();
        if (!codeIds.isEmpty()) {
            codeMap = new Map<Id, CodeSet>([
                SELECT Id, Name
                FROM CodeSet
                WHERE Id IN :codeIds
            ]);
        }

        // Filter to candidate observations and capture values
        Set<Id> candidateObservationIds = new Set<Id>();
        Map<Id, Decimal> observationHbA1cMap = new Map<Id, Decimal>();

        for (CareObservation obs : newObservations) {
            CodeSet code = codeMap.get(obs.CodeId);
            String codeName = (code == null) ? null : code.Name;

            // Only process finalized HbA1c observations with valid data meeting Warning threshold
            if (codeName == 'HbA1c'
                && obs.ObservationStatus == 'final'
                && obs.ObservedValueType == 'Quantity'
                && obs.ObservedValueNumerator != null
                && obs.ObservedSubjectId != null
                && obs.ObservedValueNumerator >= thresholds.Warning_Percentage__c) {

                candidateObservationIds.add(obs.Id);
                observationHbA1cMap.put(obs.Id, obs.ObservedValueNumerator);
            }
        }

        if (candidateObservationIds.isEmpty()) {
            return; // Nothing to do
        }

        // Bulk query Tasks once for all candidate observations (fix: no SOQL in loop)
        Map<Id, List<Task>> existingByObservation = new Map<Id, List<Task>>();
        for (Id idVal : candidateObservationIds) {
            existingByObservation.put(idVal, new List<Task>());
        }

        for (Task t : [
            SELECT Id, WhatId, Subject, Status, CreatedDate
            FROM Task
            WHERE WhatId IN :candidateObservationIds
              AND Subject LIKE '%HbA1c Follow-up%'
              AND Status != 'Completed'
              AND CreatedDate = LAST_N_DAYS:30
        ]) {
            List<Task> lst = existingByObservation.get(t.WhatId);
            if (lst != null) lst.add(t);
        }

        // Build tasks to create (fix: no DML inside loop, set required fields)
        List<Task> tasksToCreate = new List<Task>();
        Date today = Date.today();

        for (Id observationId : candidateObservationIds) {
            List<Task> existing = existingByObservation.get(observationId);
            if (existing != null && !existing.isEmpty()) {
                continue; // Skip if a recent open follow-up already exists
            }

            Decimal hba1cValue = observationHbA1cMap.get(observationId);

            Task followUpTask = new Task();
            followUpTask.Subject = 'HbA1c Follow-up Required - ' + today.format();
            followUpTask.WhatId = observationId;
            followUpTask.ActivityDate = today; // fix: required field

            // Priority based on thresholds
            if (hba1cValue != null && hba1cValue >= thresholds.Critical_Percentage__c) {
                followUpTask.Priority = 'High';
            } else if (hba1cValue != null && hba1cValue >= thresholds.Warning_Percentage__c) {
                followUpTask.Priority = 'Normal';
            } else {
                followUpTask.Priority = 'Low';
            }

            followUpTask.Status = 'Not Started';
            followUpTask.Type = 'Call';

            // Safe description with null checks (fix)
            String hba1cText = (hba1cValue == null) ? 'N/A' : String.valueOf(hba1cValue);
            followUpTask.Description =
                'Patient has new HbA1c level of ' + hba1cText +
                '%. Schedule follow-up appointment to review diabetes management plan and medication adherence. ' +
                'Thresholds: Target <' + String.valueOf(thresholds.Target_Percentage__c) +
                '%, Warning ≥' + String.valueOf(thresholds.Warning_Percentage__c) +
                '%, Critical ≥' + String.valueOf(thresholds.Critical_Percentage__c) + '%.';

            tasksToCreate.add(followUpTask);
        }

        if (!tasksToCreate.isEmpty()) {
            // Single bulk DML (fix)
            insert tasksToCreate;
        }
    }
}
