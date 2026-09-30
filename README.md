# Speech-to-Text-0
Suite de commandes écritent en Turbo Pascal/Free Pascal pour la compréhension du son (Speech-to-Text).

<h3>Liste des fichiers</h3>

Voici la liste des différents fichiers proposés dans Speech-to-Text-0 :

<table>
	<tr>
		<th>Nom</th>
		<th>Description</th>
	</tr>
	<tr>
    <td><b>AIFF2WAV.PAS</b></td>
    <td>Cette commande permet de lancer le convertisseur AIFF/AIFF-C PCM vers WAV PCM.</td>
  </tr>
  <tr>	
    <td><b>MFA.PAS</b></td>
    <td>Cette commande permet d'effectuer l'alignement acoustique natif GMM-HMM.</td>
  </tr>
  <tr>
    <td><b>MOD2WAV.PAS</b></td>
    <td>Cette commande permet de lancer le convertisseur MOD ProTracker vers WAV PCM16.</td>
  </tr>
  <tr>
      <td><b>MP32WAV.PAS</b></td>
      <td>Cette commande permet de convertir un MP3 vers WAV PCM 16 bits, decodeur intégré.</td>
  </tr>
  <tr>
      <td><b>PLAYAIFF.PAS</b></td>
      <td>Cette commande permet de lancer le lecteur de fichiers AIFF.</td>
  </tr>
  <tr>
      <td><b>PLAYMOD.PAS</b></td>
     <td>Cette commande permet de lancer le lecteur de fichiers MOD.</td>
  </tr>
  <tr>  
      <td><b>PLAYMP3.PAS</b></td>
      <td>Cette commande permet de laner le lecteur de MP3.</td>
  </tr>
  <tr>
      <td><b>PLAYVOC.PAS</b></td>
      <td>Cette commande permet de lancer le lecteur audio pour les fichiers VOC.</td>
  </tr>
  <tr>
      <td><b>PLAYWAV.PAS</b></td>
      <td>Cette commande permet de lancer lecteur de fichier WAV.</td>
  </tr>
  <tr> 
     <td><b>VOC2WAV.PAS</b></td>
    <td>Cette commande permet de lancer le convertisseur Creative VOC PCM vers WAV PCM16.</td>
  </tr>
  <tr>
      <td><b>WAV2FRA.PAS</b></td>
      <td>Cette commande permet d'effectuer la transcription francaise locale.</td>
  </tr>
  <tr>
    <td><b>WHISPER-CLI.PAS</b></td>
      <td>Cette commande permet de lancer le moteur Whisper natif en Pascal.</td>
  </tr>
</table>

<h2>Compilation</h2>
	
Les fichiers Pascal n'ont aucune dépendances, il suffit de télécharger le fichier désiré et de le compiler avec Free Pascal avec la syntaxe de commande  :

<pre><b>fpc</b> <i>LEFICHIER.PAS</i></pre>
	
Sinon, vous pouvez également le compiler avec le Turbo Pascal à l'aide de la syntaxe de commande suivante :	

<pre><b>tpc</b> <i>LEFICHIER.PAS</i></pre>
	
Par exemple, si vous voulez compiler PLAYMP3.PAS, vous devrez tapez la commande suivante :

<pre><b>fpc</b> PLAYMP3.PAS</pre>

<h2>Licence</h2>
<ul>
 <li>Le code source est publié sous la licence <a href="https://github.com/gladir/GEOPHYSIX/blob/main/LICENSE">MIT</a>.</li>
 <li>Le paquet original est publié sous la licence <a href="https://github.com/gladir/GEOPHYSIX/blob/main/LICENSE">MIT</a>.</li>
</ul>
