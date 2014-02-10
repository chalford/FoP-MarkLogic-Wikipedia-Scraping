module namespace wiki = "http://ixxus.com/wikipediascraping";

import module namespace functx = "http://www.functx.com" at "/MarkLogic/functx/functx-1.0-nodoc-2007-01.xqy";
import module namespace sem = "http://marklogic.com/semantics" at "/MarkLogic/semantics.xqy";
import module namespace util = "http://ixxus.com/util" at "Utilities.xqy";

declare namespace wikimedia = "http://www.mediawiki.org/xml/export-0.8/";

declare variable $wikipediaBaseUrl as xs:string := "http://en.wikipedia.org/wiki/";

declare function ImportPagesFromWikipediaExportFile($xmlFileLocation as xs:string)
{
	let $page := xdmp:document-get($xmlFileLocation)
	return
		for $title in $page//wikimedia:title/text()
		let $title := fn:replace($title, " ", "_")
		return
			ImportWikipediaPage($title, fn:true(), "")
					
};

declare function ImportWikipediaPage($title as xs:string, $downloadLinkedPages as xs:boolean, $startingDocumentUri as xs:string)
{
	let $url := CreateWikipediaLinkFromTitle($title)
	let $page := DownloadWikipediaPage($url)
	return
		if (fn:empty($page)) then
			()
		else
			if (PageIsCategoryPage($page)) then
				DownloadLinkedPagesFromCategoryPage($page)
			else
				SavePageToDatabase($page, $downloadLinkedPages, $startingDocumentUri)
};

declare function CreateWikipediaLinkFromTitle($title) as xs:string
{
	fn:concat($wikipediaBaseUrl, $title)
};

declare function DownloadWikipediaPage($url as xs:string) as node()?
{
	try
	{
		let $_ := xdmp:sleep(1000)
		let $_ := xdmp:log(fn:concat("About to download page from [", $url, "]")) 
		let $responseAndPage := xdmp:http-get
			(
				$url,
				<options xmlns="xdmp:http-get">
					<format xmlns="xdmp:document-get">xml</format>
				</options>
			)
		let $response := $responseAndPage[1]
		let $responseCode := $response/*:code/text()
		let $_ := xdmp:log(fn:concat("Got response code [", $responseCode, "]")) 
		return
			if ($responseCode = 200) then
				$responseAndPage[2]
			else
				xdmp:log("Not downloading page")
	}
	catch ($error)
	{
		xdmp:log($error)
	}
};

declare function PageIsCategoryPage($page as node()) as xs:boolean
{
	let $title := GetTitleFromPage($page)
	return
		if (fn:contains($title, "Category:")) then
			fn:true()
		else
			fn:false()
};

declare function GetTitleFromPage($page as node())
{
	let $title := fn:replace($page/html/head/title/text(), " - Wikipedia, the free encyclopedia", "")
	return
		$title
};

declare function DownloadLinkedPagesFromCategoryPage($page as node())
{
	let $linksDiv := $page//*:div[@id="mw-pages"]
	let $links := GetLinkedPages($linksDiv)
	return
		for $link in $links
		return ImportWikipediaPage($link, fn:true(), "")
			
};

declare function GetLinkedPages($content as node()) as item()*
{
	let $links := fn:distinct-values
		(
			$content//a
			[@href
				[
					not(contains(., "#")) 
					and not(contains(., "File:")) 
					and not(contains(., "action=edit"))
					and not(contains(., "Special:"))
					and not(contains(., "Help:"))
					and not(contains(., "Wikipedia:"))
					and not(contains(., "Portal:"))
					and not(contains(., "Category:"))
					and not(contains(., "Template"))
					and starts-with(., "/wiki/")
				]
			]/@href)
	return
		for $link in $links
		return
			fn:replace($link, "/wiki/", "")
};

declare function SavePageToDatabase($page as node(), $downloadLinkedPages as xs:boolean, $startingDocumentUri as xs:string)
{
	let $command := fn:concat
		("
			declare variable $filenameExt external;
			declare variable $documentExt external;
			xdmp:document-insert($filenameExt, $documentExt)
		")
	
	let $document := CreateDocument($page)
	let $filename := GetTitleFromPage($page)
	let $filename := fn:concat("/Article/", $filename, ".xml")

	let $_ := util:RunCommandInDifferentTransaction
		(
			$command, 
			(xs:QName("filenameExt"), $filename, xs:QName("documentExt"), $document)
		)
	
	let $content := $page/html/body/div[@id="content"]
	let $_ := SaveImagesToDatabase($content, $filename)
	let $_ := CreateTriplesForLinkedPage($filename, $startingDocumentUri)
	return
		if ($downloadLinkedPages = fn:true()) then
			let $links := GetLinkedPages($content)
			return
				DownloadLinkedPages($links, $filename)
		else
			()
};

declare function CreateDocument($page as node()) as element()
{
	let $title := GetTitleFromPage($page)
	let $content := $page/html/body/div[@id="content"]/div[@id="bodyContent"]/div[@id="mw-content-text"]
	let $headings := GetSectionHeadings($content)
	return
		<article>
			<title>{$title}</title>
			<summary>
			{
				for $paragraph in $content/p[not(preceding-sibling::div[@id="toc"])]
				return
					fn:string($paragraph)
			}
			</summary>
			<sections>
			{
				for $heading in $headings
				let $nextHeading := $heading/following-sibling::h2[1]
				let $fullSection := $heading/following-sibling::* except ($nextHeading, $nextHeading/following-sibling::*)
				let $sectionContent := $fullSection except ($fullSection[self::h3], $fullSection[self::h3]/following-sibling::*)
				return
					<section>
						<heading>{$heading/span/text()}</heading>
						<content>{$sectionContent}</content>
						<sub-sections>
						{
							for $subheading in $content//h3[span[@class='mw-headline']]
							let $headingBeforeSubHeading := $subheading/preceding-sibling::h2[1]
								return
									if ($headingBeforeSubHeading = $heading) then
									let $nextSubHeading := $subheading/following-sibling::h3[1]
									let $fullSubSection := $subheading/following-sibling::* except ($nextSubHeading, $nextSubHeading/following-sibling::*)
									let $subSectionContent := $fullSubSection except ($fullSubSection[self::h4], $fullSubSection[self::h4]/following-sibling::*)
									return
										<section>
											<title>{$subheading/span/text()}</title>
											<content>{$subSectionContent}</content>
											<sub-sections>
											{
												for $subSubHeading in $content//h4[span[@class='mw-headline']]
												let $subHeadingBeforeSubSubHeading := $subSubHeading/preceding-sibling::h3[1]
												return
													if ($subHeadingBeforeSubSubHeading = $subheading) then
														let $nextSubSubHeading := $subSubHeading/following-sibling::h4[1]
														let $fullSubSubSection := $subSubHeading/following-sibling::* except ($nextSubSubHeading, $nextSubSubHeading/following-sibling::*)
														let $subSubSectionContent := $fullSubSubSection except ($fullSubSubSection[self::h5], $fullSubSubSection[self::h5]/following-sibling::*)
														return
															<section>
															<title>{$subSubHeading/span/text()}</title>
															<content>{$subSubSectionContent}</content>
															</section>
													else
													()
											}
											</sub-sections>
										</section>
									else
										()
						}
						</sub-sections>
					</section>
			}
			</sections>
			<linkedPages/>
			<images/>
		</article>
};

declare function GetSectionHeadings($content as node()) as item()*
{
	$content/h2
		[
			span
				[
					@class="mw-headline"
					and not(./text() = "References") 
					and not(./text() = "Further reading")
					and not(./text() = "See also")
					and not(./text() = "External links")
				]
		]
};

declare function SaveImagesToDatabase($content as node(), $documentUri as xs:string)
{
	let $insertCommand := CreateInsertImageCommand()
	let $addTripleCommand := CreateTripleCommand()
	
	let $imageDivs := $content//div[@class="thumbinner"]
	return
		for $imageDiv in $imageDivs
		let $imageUrl := GetImageUrl($imageDiv)
		let $filename := GetImageFilename($imageUrl)
		let $_ := util:RunCommandInDifferentTransaction
			(
				$insertCommand, 
				(xs:QName("urlExt"), $imageUrl, xs:QName("filenameExt"), $filename)
			)
		let $_ := util:RunCommandInDifferentTransaction
			(
				$addTripleCommand,
				(
					xs:QName("documentUriExt"), $documentUri, 
					xs:QName("nodeToAddToExt"), "images",
					xs:QName("subjectUriExt"), $filename, 
					xs:QName("predicateExt"), "included in",
					xs:QName("objectUriExt"), $documentUri
				)
			)
		return
			()
};

declare function CreateInsertImageCommand() as xs:string
{
	fn:concat
		('
			declare variable $urlExt external;
			declare variable $filenameExt external;
			xdmp:document-load(
				$urlExt,
				<options xmlns="xdmp:document-load">
					<uri>
						{$filenameExt}
					</uri>
				</options>
				)
		')
};

declare function CreateTripleCommand() as xs:string
{
	fn:concat
		('
			declare variable $documentUriExt external;
			declare variable $nodeToAddToExt external;
			declare variable $subjectUriExt external;
			declare variable $predicateExt external;
			declare variable $objectUriExt external;
			
			let $document := fn:doc($documentUriExt)
			let $imagesNode := $document/article/*[local-name(.) = $nodeToAddToExt]
			return
				xdmp:node-insert-child
					(
						$imagesNode, 
						<triple>
						{
							sem:triple($subjectUriExt, $predicateExt, $objectUriExt)
						}
						</triple>
					)
		')
};

declare function GetImageUrl($imageDiv as node()) as xs:string
{
	let $imageTag := $imageDiv//img[@class="thumbimage"]
	let $imageUrl := data($imageTag/@src)
	let $imageUrl := fn:replace($imageUrl, "//", "http://")
	let $imageUrl := fn:replace($imageUrl, "/thumb", "")
	let $imageUrl := functx:substring-before-last($imageUrl, "/")
	return
		$imageUrl
};

declare function GetImageFilename($url as xs:string) as xs:string
{
	let $filename := functx:substring-after-last($url, "/")
	let $filename := fn:concat("/Image/", $filename)
	return
		$filename
};

declare function CreateTriplesForLinkedPage($documentUri as xs:string, $startingDocumentUri as xs:string)
{
	if ($startingDocumentUri = "") then
		xdmp:log(fn:concat("Starting document URI: ", $startingDocumentUri))
	else
		let $_ := xdmp:log(fn:concat("Starting document URI: [", $startingDocumentUri, "]"))
		let $addTripleCommand := CreateTripleCommand()
		let $_ := util:RunCommandInDifferentTransaction
			(
				$addTripleCommand,
				(
					xs:QName("documentUriExt"), $documentUri, 
					xs:QName("nodeToAddToExt"), "linkedPages",
					xs:QName("subjectUriExt"), $startingDocumentUri, 
					xs:QName("predicateExt"), "links to",
					xs:QName("objectUriExt"), $documentUri
				)
			)
		return
			()
		
};

declare function DownloadLinkedPages($links as item()*, $startingDocumentUri as xs:string)
{
	for $link in $links
	return
		ImportWikipediaPage($link, fn:false(), $startingDocumentUri)
};