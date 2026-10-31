/* Repeat the controlled-provider regressions and strict TypeScript checks.
 * Platform declarations are stubbed here; a separate SDK build is still required. */
const {spawnSync}=require('node:child_process');
const path=require('node:path');
const suites=['react-runner.test.cjs','react-compatibility.test.cjs','parallel-runner.test.cjs','support-models.test.cjs','integration-contract.test.cjs',
 'integration-lifecycle.test.cjs','index-lifecycle.test.cjs','tablet-queue.test.cjs','tablet-customization.test.cjs','task-progress.test.cjs','inference-budget.test.cjs',
 'tool-contracts.test.cjs','plain-chat.test.cjs','nearby-background.test.cjs','task-telemetry.test.cjs','task-reporter.test.cjs',
 'utf8-repair.test.cjs','react-core.typecheck.cjs','support-models.typecheck.cjs','integration-contract.typecheck.cjs'];
const selected=process.argv.includes('--portable') ? suites.filter(suite=>suite!=='support-models.typecheck.cjs') : suites;
if(selected.length!==suites.length)console.log('Portable mode excludes the check requiring HarmonyOS SDK declarations.');
let failed=0;
for(const suite of selected){
 console.log('\nRunning '+suite);
 const result=spawnSync(process.execPath,[path.join(__dirname,suite)],{stdio:'inherit',env:process.env});
 if(result.error){console.error(result.error);failed++;}
 else if(result.status!==0)failed++;
}
console.log('\n'+(selected.length-failed)+'/'+selected.length+' suites passed; SDK compilation and device tests are separate.');
if(failed)process.exitCode=1;
