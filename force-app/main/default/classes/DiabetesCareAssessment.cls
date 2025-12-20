/**
 * @description Apex class for assessing diabetes care based on HbA1c values and program enrollment.
 * This class is designed to be invoked from Flow, Process Builder, or other automation tools.
 * It evaluates patients' latest HbA1c values and their enrollment status in diabetes care programs.
 */
public with sharing class DiabetesCareAssessment {
    
    /**
     * Input wrapper for the invocable method.
     * Represents a request to assess a patient's diabetes care.
     */
    public class AssessmentRequest {
        /**
         * The Salesforce ID of the patient/account to assess.
         * @required true
         */
        @InvocableVariable(required=true)
        public Id patientId;
        
        /**
         * Number of days to look back for observations (currently unused but included in structure).
         */
        @InvocableVariable
        public Integer daysLookback;
        
        /**
         * Default constructor for the AssessmentRequest class.
         */
        public AssessmentRequest() {}
        
        /**
         * Parameterized constructor for the AssessmentRequest class.
         * @param patientId The Salesforce ID of the patient to assess
         * @param daysLookback Number of days to look back for observations
         */
        public AssessmentRequest(Id patientId, Integer daysLookback) {
            this.patientId = patientId;
            this.daysLookback = daysLookback;
        }
    }
    
    /**
     * Output wrapper for the invocable method.
     * Contains the results of the diabetes care assessment for a patient.
     */
    public class AssessmentResult {
        /**
         * The Salesforce ID of the patient that was assessed.
         */
        @InvocableVariable
        public Id patientId;
        
        /**
         * The latest HbA1c value found for the patient (can be null if no observation found).
         */
        @InvocableVariable
        public Decimal hba1cValue;
        
        /**
         * Categorized risk level based on HbA1c value.
         * Categories: Well Controlled (< 7.0%), Needs Attention (>= 7.0% and < 9.0%), 
         * High Risk/Urgent (>= 9.0%), No Data Available (no valid observation).
         */
        @InvocableVariable
        public String riskCategory;
        
        /**
         * Indicates whether the patient is enrolled in an active Diabetes care program.
         */
        @InvocableVariable
        public Boolean isInDiabetesProgram;
        
        /**
         * Contains error message if processing failed for this patient (null if successful).
         */
        @InvocableVariable
        public String errorMessage;
        
        /**
         * Default constructor for the AssessmentResult class.
         */
        public AssessmentResult() {}
        
        /**
         * Parameterized constructor for the AssessmentResult class.
         * @param patientId The Salesforce ID of the patient that was assessed
         */
        public AssessmentResult(Id patientId) {
            this.patientId = patientId;
            this.isInDiabetesProgram = false;
            this.riskCategory = 'No Data Available';
        }
    }
    
    /**
     * Main invocable method to assess patient diabetes care.
     * @param requests List of AssessmentRequest objects containing patient IDs to assess
     * @return List of AssessmentResult objects with assessment outcomes
     */
    @InvocableMethod(
        label='Assess Patient' 
        description='Assesses patient diabetes care based on HbA1c values and program enrollment'
    )
    public static List<AssessmentResult> assessPatient(List<AssessmentRequest> requests) {
        List<AssessmentResult> results = new List<AssessmentResult>();
        
        // Input validation
        if (requests == null || requests.isEmpty()) {
            return results;
        }
        
        // Extract patient IDs and create mapping
        Set<Id> patientIds = new Set<Id>();
        Map<Id, AssessmentRequest> requestMap = new Map<Id, AssessmentRequest>();
        
        for (AssessmentRequest req : requests) {
            if (req.patientId != null) {
                patientIds.add(req.patientId);
                requestMap.put(req.patientId, req);
            }
        }
        
        // Get HbA1c CodeSet ID
        Id hba1cCodeSetId = getHbA1cCodeSetId();
        if (hba1cCodeSetId == null) {
            // Create error results for all patients
            for (Id pid : patientIds) {
                AssessmentResult result = new AssessmentResult(pid);
                result.errorMessage = 'HbA1c CodeSet not found in the system';
                results.add(result);
            }
            return results;
        }
        
        // Get latest HbA1c observations
        Map<Id, CareObservation> observationMap = getLatestHbA1cObservations(patientIds, hba1cCodeSetId);
        
        // Check active diabetes programs
        Map<Id, Boolean> programEnrollmentMap = checkActiveDiabetesPrograms(patientIds);
        
        // Process each patient
        for (Id patientId : patientIds) {
            AssessmentResult result = new AssessmentResult(patientId);
            
            try {
                CareObservation latestObs = observationMap.get(patientId);
                
                if (latestObs != null && latestObs.ObservedValueNumerator != null) {
                    result.hba1cValue = latestObs.ObservedValueNumerator;
                    
                    // Risk categorization
                    if (result.hba1cValue < 7.0) {
                        result.riskCategory = 'Well Controlled';
                    } else if (result.hba1cValue >= 7.0 && result.hba1cValue < 9.0) {
                        result.riskCategory = 'Needs Attention';
                    } else if (result.hba1cValue >= 9.0) {
                        result.riskCategory = 'High Risk/Urgent';
                    }
                }
                
                // Set program enrollment status
                result.isInDiabetesProgram = programEnrollmentMap.get(patientId) != null ? programEnrollmentMap.get(patientId) : false;
                
            } catch (Exception e) {
                result.errorMessage = 'Error processing patient ' + patientId + ': ' + e.getMessage();
            }
            
            results.add(result);
        }
        
        return results;
    }
    
    /**
     * Helper method to retrieve the Salesforce ID of the CodeSet record named 'HbA1c'.
     * @return Id of the HbA1c CodeSet or null if not found
     */
    private static Id getHbA1cCodeSetId() {
        List<CodeSet> codeSets = [
            SELECT Id 
            FROM CodeSet 
            WHERE Name = 'HbA1c' 
            LIMIT 1
        ];
        
        return codeSets.isEmpty() ? null : codeSets[0].Id;
    }
    
    /**
     * Helper method to retrieve the most recent HbA1c observation for each patient.
     * @param patientIds Set of patient/account IDs to query
     * @param hba1cCodeSetId The ID of the HbA1c CodeSet
     * @return Map of patient ID to the latest HbA1c observation
     */
    private static Map<Id, CareObservation> getLatestHbA1cObservations(Set<Id> patientIds, Id hba1cCodeSetId) {
        Map<Id, CareObservation> observationMap = new Map<Id, CareObservation>();
        
        // Early return if no patients or no HbA1c code set ID
        if (patientIds.isEmpty() || hba1cCodeSetId == null) {
            return observationMap;
        }
        
        // Query latest HbA1c observations
        List<CareObservation> observations = [
            SELECT Id, ObservedSubjectId, ObservedValueNumerator, EffectiveDateTime
            FROM CareObservation
            WHERE CodeId = :hba1cCodeSetId
              AND ObservedSubjectId IN :patientIds
              AND ObservationStatus = 'Final'
              AND ObservedValueType = 'Quantity'
              AND ObservedValueNumerator != null
            ORDER BY EffectiveDateTime DESC NULLS LAST
            LIMIT 1000
        ];
        
        // Create map with one observation per patient (latest due to ordering)
        for (CareObservation obs : observations) {
            if (!observationMap.containsKey(obs.ObservedSubjectId)) {
                observationMap.put(obs.ObservedSubjectId, obs);
            }
        }
        
        return observationMap;
    }
    
    /**
     * Helper method to determine which patients are enrolled in active Diabetes care programs.
     * @param patientIds Set of patient/account IDs to check
     * @return Map of patient ID to boolean indicating active enrollment in Diabetes program
     */
    private static Map<Id, Boolean> checkActiveDiabetesPrograms(Set<Id> patientIds) {
        Map<Id, Boolean> enrollmentMap = new Map<Id, Boolean>();
        
        // Early return if no patients
        if (patientIds.isEmpty()) {
            return enrollmentMap;
        }
        
        // Initialize all patients to false (not enrolled)
        for (Id pid : patientIds) {
            enrollmentMap.put(pid, false);
        }
        
        // Query active enrollments in Diabetes programs
        List<CareProgramEnrollee> enrollees = [
            SELECT Id, CareProgramId, AccountId, Status
            FROM CareProgramEnrollee
            WHERE AccountId IN :patientIds
              AND Status = 'Active'
              AND CareProgramId IN (SELECT Id FROM CareProgram WHERE Name LIKE '%Diabetes%')
        ];
        
        // Update enrollment status for patients with active Diabetes program enrollments
        for (CareProgramEnrollee enrollee : enrollees) {
            enrollmentMap.put(enrollee.AccountId, true);
        }
        
        return enrollmentMap;
    }
}
